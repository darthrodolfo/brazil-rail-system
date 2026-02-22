-- ==============================================================================
-- BRAZIL RAIL SYSTEM — Schema v2.0
-- Conformidade: LGPD BR (Lei 13.709/2018) + PIPEDA CA
-- Estratégia: Criptografia Híbrida (Opção C)
--   - Dados sensíveis → AES-256-GCM nível aplicação
--   - Dados comuns    → TDE (Transparent Data Encryption) nível infraestrutura  
--   - Audit logs      → Hash chain verificável (append-only)
-- ==============================================================================

-- ==============================================================================
-- 0. EXTENSÕES
-- ==============================================================================
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ==============================================================================
-- 1. ENUMS
-- ==============================================================================
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'train_status') THEN
        CREATE TYPE train_status AS ENUM (
            'ACTIVE', 'MAINTENANCE', 'OUT_OF_SERVICE', 'MUSEUM_PIECE'
        );
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN
        CREATE TYPE user_role AS ENUM (
            'ADMIN', 'OPERATOR', 'MAINTENANCE', 'HISTORIAN'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'data_category') THEN
        CREATE TYPE data_category AS ENUM (
            'PERSONAL',      -- Nome, email — LGPD Art. 5 I
            'SENSITIVE',     -- CPF, biometria — LGPD Art. 11 / PIPEDA explicit consent
            'OPERATIONAL',   -- GPS, velocidade — não pessoal isoladamente
            'ANONYMOUS'      -- Dados anonimizados — fora do escopo LGPD/PIPEDA
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'audit_action') THEN
        CREATE TYPE audit_action AS ENUM (
            'CREATE',
            'READ',               -- LGPD exige rastrear acesso a dado pessoal
            'UPDATE',
            'DELETE',
            'CONSENT_GRANTED',
            'CONSENT_REVOKED',    -- LGPD Art. 8 §5 / PIPEDA: revogação a qualquer tempo
            'DATA_EXPORT',        -- LGPD Art. 18 V: portabilidade
            'DATA_ANONYMIZED',
            'KEY_ROTATED',        -- Rotação de chave criptográfica — NOVO
            'LOGIN',
            'LOGIN_FAILED',
            'BIOMETRIC_ENROLLED', -- Cadastro de biometria — NOVO (evento específico)
            'BIOMETRIC_ACCESS',
            'BIOMETRIC_DELETED',  -- NOVO: exclusão específica de biometria
            'CROSS_BORDER_TRANSFER'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'key_status') THEN
        CREATE TYPE key_status AS ENUM (
            'ACTIVE',      -- chave em uso
            'ROTATING',    -- em processo de rotação (registros sendo re-criptografados)
            'RETIRED',     -- aposentada, não criptografa mais mas ainda decripta
            'COMPROMISED'  -- comprometida, todos os registros devem ser re-criptografados
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'biometric_purpose') THEN
        CREATE TYPE biometric_purpose AS ENUM (
            'AUTHENTICATION_ONLY',  -- apenas login
            'ACCESS_CONTROL',       -- controle de acesso a áreas físicas
            'FRAUD_PREVENTION',     -- prevenção de fraude
            'TIME_ATTENDANCE'       -- controle de ponto
        );
    END IF;
END $$;

-- ==============================================================================
-- 2. ENCRYPTION_KEYS — Gerenciamento de chaves criptográficas
-- ==============================================================================
-- Esta tabela NÃO armazena as chaves em si (isso vai para um KMS: AWS KMS, 
-- HashiCorp Vault, Azure Key Vault).
-- Armazena REFERÊNCIAS às chaves — o ID que o KMS usa para identificá-las.
-- Em dev local: o valor real da chave fica apenas no .env.
-- Em produção: o app chama o KMS passando o key_id para obter a chave.

CREATE TABLE IF NOT EXISTS encryption_keys (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Identificador que o KMS usa (ex: "arn:aws:kms:ca-central-1:xxx" ou "vault/transit/brs-biometric-v1")
    key_reference   VARCHAR(500) NOT NULL UNIQUE,
    
    -- Identificador amigável para queries (ex: "biometric-v1", "personal-v2")
    key_alias       VARCHAR(100) NOT NULL UNIQUE,
    
    -- Para qual tipo de dado esta chave é usada
    data_category   data_category NOT NULL,
    purpose         VARCHAR(100) NOT NULL,
    -- Exemplos: 'biometric_encryption', 'personal_data_encryption', 'document_encryption'
    
    status          key_status DEFAULT 'ACTIVE',
    
    -- Jurisdição — LGPD BR exige que chaves de dados BR residam em território BR
    -- (ou país com nível de proteção adequado reconhecido pela ANPD)
    jurisdiction    VARCHAR(2)[] DEFAULT '{BR}', -- '{BR}', '{CA}', '{BR,CA}'
    
    -- Rotação automática
    rotates_at      TIMESTAMP WITH TIME ZONE, -- quando deve ser rotacionada
    retired_at      TIMESTAMP WITH TIME ZONE, -- quando foi aposentada
    
    -- Metadados do algoritmo (documentação, não a chave)
    algorithm       VARCHAR(50) DEFAULT 'AES-256-GCM',
    key_size_bits   INTEGER DEFAULT 256,
    
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_by      UUID -- referência ao user que criou (FK adicionada depois)
);

-- Seeds de chaves (referências apenas — valores reais no KMS/.env)
INSERT INTO encryption_keys (key_reference, key_alias, data_category, purpose, jurisdiction, rotates_at)
VALUES
    ('local/dev/personal-v1',  'personal-v1',  'PERSONAL',   'personal_data_encryption',  '{BR,CA}', CURRENT_TIMESTAMP + INTERVAL '90 days'),
    ('local/dev/sensitive-v1', 'sensitive-v1', 'SENSITIVE',  'document_encryption',        '{BR}',    CURRENT_TIMESTAMP + INTERVAL '90 days'),
    ('local/dev/biometric-v1', 'biometric-v1', 'SENSITIVE',  'biometric_encryption',       '{BR}',    CURRENT_TIMESTAMP + INTERVAL '90 days')
ON CONFLICT (key_alias) DO NOTHING;

-- ==============================================================================
-- 3. USERS — Conformidade completa LGPD + PIPEDA
-- ==============================================================================
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- ── DADOS PESSOAIS — AES-256-GCM nível aplicação ──────────────────────────
    -- O banco nunca vê em claro. DBA não consegue ler. Backup seguro sem TDE.
    -- Trio obrigatório por campo criptografado: encrypted + iv + auth_tag
    full_name_encrypted     TEXT NOT NULL,
    full_name_iv            TEXT NOT NULL,  -- IV único por registro (randomBytes(16))
    full_name_auth_tag      TEXT NOT NULL,  -- GCM auth tag — detecta adulteração
    full_name_key_id        UUID REFERENCES encryption_keys(id), -- qual chave usou
    
    -- Hash HMAC-SHA256 para busca determinística segura
    -- HMAC com SECRET_KEY do .env — diferente de SHA256 puro (resiste rainbow table)
    email_hmac              TEXT UNIQUE NOT NULL,
    
    -- Documento (CPF/Passaporte) — dado sensível LGPD Art. 11
    document_id_encrypted   TEXT,
    document_id_iv          TEXT,
    document_id_auth_tag    TEXT,
    document_id_key_id      UUID REFERENCES encryption_keys(id),
    
    -- ── AUTENTICAÇÃO ──────────────────────────────────────────────────────────
    password_hash           TEXT NOT NULL,          -- bcrypt, rounds >= 12
    biometric_public_key    TEXT,                   -- chave pública FIDO2 (não sensível)
    
    -- ── BIOMETRIA FACIAL — DADO SENSÍVEL ESPECIAL ─────────────────────────────
    -- LGPD Art. 11: base legal + consentimento específico + finalidade declarada
    -- PIPEDA: explicit meaningful consent, purpose limitation
    face_signature_vector   BYTEA,                  -- vetor criptografado AES-256-GCM
    face_vector_iv          TEXT,                   -- IV do vetor biométrico
    face_vector_auth_tag    TEXT,                   -- GCM auth tag do vetor
    face_vector_key_id      UUID REFERENCES encryption_keys(id), -- ← O campo que faltava
    
    -- Consentimento biométrico (LGPD Art. 11 §1 + PIPEDA)
    biometric_consent_at    TIMESTAMP WITH TIME ZONE,   -- quando clicou "Aceito"
    biometric_consent_ip    INET,                        -- de onde consentiu
    biometric_consent_version VARCHAR(20),               -- versão dos termos aceitos
    biometric_purpose       biometric_purpose,           -- para qual finalidade específica
    biometric_enrolled_at   TIMESTAMP WITH TIME ZONE,   -- quando o vetor foi gravado
    
    -- Dados não podem ser usados para finalidade diferente da declarada
    -- Este flag indica se o usuário está ciente e aceitou a finalidade atual
    biometric_purpose_acknowledged BOOLEAN DEFAULT FALSE,
    
    -- ── CONSENTIMENTO GERAL ───────────────────────────────────────────────────
    privacy_consent_at      TIMESTAMP WITH TIME ZONE,
    privacy_policy_version  VARCHAR(20),
    
    -- ── DIREITOS DO TITULAR (LGPD Art. 18 / PIPEDA Principle 9) ──────────────
    deletion_requested_at   TIMESTAMP WITH TIME ZONE,   -- Art. 18 VI: esquecimento
    deletion_scheduled_at   TIMESTAMP WITH TIME ZONE,   -- quando será executado
    data_portability_last_at TIMESTAMP WITH TIME ZONE,  -- Art. 18 V: portabilidade
    anonymization_requested_at TIMESTAMP WITH TIME ZONE, -- Art. 18 IV
    
    -- ── JURISDIÇÃO DO TITULAR ─────────────────────────────────────────────────
    -- Determina qual lei se aplica (pode ser BR e CA simultaneamente)
    data_jurisdiction       VARCHAR(2)[] DEFAULT '{BR}',
    
    -- ── METADADOS ─────────────────────────────────────────────────────────────
    role                    user_role DEFAULT 'OPERATOR',
    is_active               BOOLEAN DEFAULT TRUE,
    created_at              TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- FK circular resolvida após criação
ALTER TABLE encryption_keys 
    ADD CONSTRAINT fk_key_created_by 
    FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;

-- ==============================================================================
-- 4. TRAIN_MODELS
-- ==============================================================================
CREATE TABLE IF NOT EXISTS train_models (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    model_name          VARCHAR(100) NOT NULL,
    main_image_url      VARCHAR(500),
    technical_video_url VARCHAR(500),
    engine_sound_url    VARCHAR(500),
    historical_context  TEXT,
    is_legendary        BOOLEAN DEFAULT FALSE,
    metadata            JSONB DEFAULT '{}',
    created_at          TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ==============================================================================
-- 5. TRAIN_UNITS
-- ==============================================================================
CREATE TABLE IF NOT EXISTS train_units (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    serial_number       VARCHAR(50) UNIQUE NOT NULL,
    model_id            UUID REFERENCES train_models(id) ON DELETE RESTRICT,
    
    -- Dado operacional — não é dado pessoal isoladamente
    -- Mas SE vinculado a um operador identificável, passa a ser pessoal (LGPD Art. 5)
    current_lat         DECIMAL(9,6),
    current_lng         DECIMAL(9,6),
    altitude_meters     INTEGER,
    current_speed_kmh   INTEGER,
    
    -- FK para usuário — aqui o GPS VIRA dado pessoal (localização do operador)
    last_operator_id    UUID REFERENCES users(id) ON DELETE SET NULL,
    current_status      train_status DEFAULT 'ACTIVE',
    
    created_at          TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ==============================================================================
-- 6. AUDIT_LOGS — Append-only com hash chain verificável
-- ==============================================================================
CREATE TABLE IF NOT EXISTS audit_logs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- O QUE aconteceu
    action          audit_action NOT NULL,
    table_name      VARCHAR(100) NOT NULL,
    record_id       UUID,
    data_category   data_category NOT NULL,
    
    -- QUEM fez
    actor_user_id   UUID REFERENCES users(id) ON DELETE SET NULL,
    actor_ip        INET NOT NULL,
    actor_user_agent TEXT,
    
    -- Jurisdição aplicável no momento do evento
    applicable_law  VARCHAR(2)[] NOT NULL DEFAULT '{BR}',
    -- Preenchido automaticamente baseado em data_jurisdiction do usuário
    
    -- Contexto da requisição
    request_id      UUID NOT NULL,
    endpoint        VARCHAR(255),
    http_method     VARCHAR(10),
    
    -- Campos alterados (nunca valores — apenas nomes dos campos)
    changed_fields  JSONB,
    -- Ex: {"fields": ["full_name_encrypted", "role"], "reason": "admin update"}
    
    -- Rotação de chave (preenchido quando action = 'KEY_ROTATED')
    old_key_id      UUID REFERENCES encryption_keys(id),
    new_key_id      UUID REFERENCES encryption_keys(id),
    
    -- Transferência internacional (preenchido quando action = 'CROSS_BORDER_TRANSFER')
    destination_country   VARCHAR(2),
    transfer_legal_basis  VARCHAR(200),
    -- LGPD Art. 33: 'adequacy_decision' | 'standard_contractual_clauses' | 'consent'
    -- PIPEDA: 'comparable_protection' | 'contractual_accountability'
    
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    
    -- Hash chain — cada log referencia o anterior (detecta adulteração)
    previous_log_id UUID REFERENCES audit_logs(id),
    previous_hash   TEXT,
    
    -- Hash deste registro (computed — não pode ser alterado após INSERT)
    record_hash     TEXT GENERATED ALWAYS AS (
        encode(
            digest(
                id::text
                || action::text
                || table_name
                || COALESCE(record_id::text, '')
                || actor_ip::text
                || COALESCE(actor_user_id::text, '')
                || created_at::text,
                'sha256'
            ),
            'hex'
        )
    ) STORED
);

CREATE INDEX IF NOT EXISTS idx_audit_actor      ON audit_logs(actor_user_id);
CREATE INDEX IF NOT EXISTS idx_audit_record     ON audit_logs(record_id);
CREATE INDEX IF NOT EXISTS idx_audit_action     ON audit_logs(action);
CREATE INDEX IF NOT EXISTS idx_audit_created    ON audit_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_crossborder
    ON audit_logs(destination_country, created_at)
    WHERE action = 'CROSS_BORDER_TRANSFER';
CREATE INDEX IF NOT EXISTS idx_audit_key_rotation
    ON audit_logs(old_key_id, new_key_id)
    WHERE action = 'KEY_ROTATED';

-- ==============================================================================
-- 7. CONSENT_RECORDS — Histórico imutável de consentimentos
-- ==============================================================================
CREATE TABLE IF NOT EXISTS consent_records (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    -- Finalidade específica — cada finalidade é um registro separado
    purpose         VARCHAR(100) NOT NULL,
    -- 'biometric_authentication' | 'location_tracking' | 'data_sharing_partners'
    -- 'marketing_communications' | 'cross_border_transfer_ca' | 'fraud_analysis'
    
    granted         BOOLEAN NOT NULL,
    policy_version  VARCHAR(20) NOT NULL,
    
    -- Jurisdição — LGPD e PIPEDA têm requisitos diferentes de consentimento
    jurisdiction    VARCHAR(2) NOT NULL DEFAULT 'BR',
    
    -- Evidência
    consent_ip      INET NOT NULL,
    consent_user_agent TEXT,
    
    -- Validade
    expires_at      TIMESTAMP WITH TIME ZONE,
    
    -- Para biometria: qual finalidade específica foi consentida
    biometric_purpose biometric_purpose,
    
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
    -- SEM updated_at — cada mudança é novo INSERT. Histórico é sagrado.
);

CREATE INDEX IF NOT EXISTS idx_consent_user    ON consent_records(user_id);
CREATE INDEX IF NOT EXISTS idx_consent_purpose ON consent_records(user_id, purpose, jurisdiction);
-- Query mais comum: "qual o último consentimento ativo do usuário X para finalidade Y?"
CREATE INDEX IF NOT EXISTS idx_consent_latest
    ON consent_records(user_id, purpose, created_at DESC)
    WHERE granted = TRUE;

-- ==============================================================================
-- 8. DATA_RETENTION_POLICIES
-- ==============================================================================
CREATE TABLE IF NOT EXISTS data_retention_policies (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name      VARCHAR(100) NOT NULL,
    field_name      VARCHAR(100),           -- NULL = política para a tabela inteira
    data_category   data_category NOT NULL,
    retention_days  INTEGER NOT NULL,
    
    legal_basis     TEXT NOT NULL,
    legal_article   VARCHAR(100),           -- "LGPD Art. 16 II" | "PIPEDA Principle 5"
    
    -- Ação ao expirar: 'DELETE' | 'ANONYMIZE' | 'ARCHIVE'
    expiry_action   VARCHAR(20) DEFAULT 'ANONYMIZE',
    
    applies_to_jurisdiction VARCHAR(2)[],
    is_active       BOOLEAN DEFAULT TRUE,
    
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO data_retention_policies
    (table_name, field_name, data_category, retention_days, legal_basis, legal_article, expiry_action, applies_to_jurisdiction)
VALUES
    -- Audit logs: 1 ano BR, 2 anos CA para dados sensíveis
    ('audit_logs',        NULL,                    'PERSONAL',   365,  'Accountability e rastreabilidade', 'LGPD Art. 37 / PIPEDA P.1',     'ARCHIVE',    '{BR,CA}'),
    ('audit_logs',        NULL,                    'SENSITIVE',  730,  'Dados sensíveis requerem retenção maior', 'LGPD Art. 11 / PIPEDA',  'ARCHIVE',    '{BR,CA}'),
    -- Biometria: 5 anos CA (PIPEDA recomendação), 2 anos BR
    ('users',             'face_signature_vector', 'SENSITIVE',  730,  'Dado biométrico — retenção mínima', 'LGPD Art. 11',                  'DELETE',     '{BR}'),
    ('users',             'face_signature_vector', 'SENSITIVE',  1825, 'Biometric data retention',         'PIPEDA Principle 5',             'DELETE',     '{CA}'),
    -- Consentimentos: 5 anos (prova em caso de auditoria regulatória)
    ('consent_records',   NULL,                    'PERSONAL',   1825, 'Prova de consentimento',           'LGPD Art. 8 / PIPEDA P.3',      'ARCHIVE',    '{BR,CA}'),
    -- GPS/telemetria: 90 dias (dado operacional sem finalidade de longo prazo)
    ('train_units',       'current_lat',           'OPERATIONAL', 90,  'Dado operacional sem vínculo pessoal prolongado', 'LGPD Art. 16', 'ANONYMIZE',  '{BR,CA}'),
    -- Chaves aposentadas: manter referência 7 anos (auditoria fiscal/legal)
    ('encryption_keys',   NULL,                    'OPERATIONAL', 2555,'Conformidade e auditabilidade de segurança', 'LGPD Art. 46',       'ARCHIVE',    '{BR,CA}')
ON CONFLICT DO NOTHING;

-- ==============================================================================
-- 9. TRIGGERS
-- ==============================================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_users_updated_at') THEN
        CREATE TRIGGER trg_users_updated_at
            BEFORE UPDATE ON users
            FOR EACH ROW EXECUTE FUNCTION update_updated_at();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_train_models_updated_at') THEN
        CREATE TRIGGER trg_train_models_updated_at
            BEFORE UPDATE ON train_models
            FOR EACH ROW EXECUTE FUNCTION update_updated_at();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_train_units_updated_at') THEN
        CREATE TRIGGER trg_train_units_updated_at
            BEFORE UPDATE ON train_units
            FOR EACH ROW EXECUTE FUNCTION update_updated_at();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_retention_updated_at') THEN
        CREATE TRIGGER trg_retention_updated_at
            BEFORE UPDATE ON data_retention_policies
            FOR EACH ROW EXECUTE FUNCTION update_updated_at();
    END IF;
END $$;

-- ==============================================================================
-- 10. ROW LEVEL SECURITY — tabelas imutáveis
-- ==============================================================================
ALTER TABLE audit_logs        ENABLE ROW LEVEL SECURITY;
ALTER TABLE consent_records   ENABLE ROW LEVEL SECURITY;

-- audit_logs: só INSERT e SELECT (nunca UPDATE/DELETE)
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'audit_insert_only' AND tablename = 'audit_logs') THEN
        CREATE POLICY audit_insert_only ON audit_logs FOR INSERT WITH CHECK (true);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'audit_select_only' AND tablename = 'audit_logs') THEN
        CREATE POLICY audit_select_only ON audit_logs FOR SELECT USING (true);
    END IF;
    -- consent_records: só INSERT e SELECT (histórico imutável)
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'consent_insert_only' AND tablename = 'consent_records') THEN
        CREATE POLICY consent_insert_only ON consent_records FOR INSERT WITH CHECK (true);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'consent_select_only' AND tablename = 'consent_records') THEN
        CREATE POLICY consent_select_only ON consent_records FOR SELECT USING (true);
    END IF;
END $$;

-- ==============================================================================
-- 11. VIEWS úteis para queries regulatórias frequentes
-- ==============================================================================

-- "Quais usuários têm biometria cadastrada sem consentimento válido?" 
-- (auditoria regulatória — ANPD pode pedir isso)
CREATE OR REPLACE VIEW v_biometric_compliance AS
SELECT 
    u.id,
    u.role,
    u.data_jurisdiction,
    u.biometric_enrolled_at,
    u.biometric_purpose,
    u.biometric_consent_at,
    u.biometric_consent_version,
    -- Tem vetor mas não tem consentimento = violação LGPD Art. 11
    CASE 
        WHEN u.face_signature_vector IS NOT NULL 
         AND u.biometric_consent_at IS NULL 
        THEN TRUE ELSE FALSE 
    END AS has_compliance_issue,
    -- Consentimento expirado?
    cr.expires_at AS consent_expires_at,
    CASE 
        WHEN cr.expires_at IS NOT NULL AND cr.expires_at < NOW() 
        THEN TRUE ELSE FALSE 
    END AS consent_expired
FROM users u
LEFT JOIN LATERAL (
    SELECT expires_at 
    FROM consent_records 
    WHERE user_id = u.id 
      AND purpose = 'biometric_authentication' 
      AND granted = TRUE
    ORDER BY created_at DESC 
    LIMIT 1
) cr ON TRUE
WHERE u.face_signature_vector IS NOT NULL;

-- "Histórico completo de consentimentos de um usuário" 
-- (direito de transparência LGPD Art. 18 VII / PIPEDA Principle 9)
CREATE OR REPLACE VIEW v_user_consent_timeline AS
SELECT
    cr.user_id,
    cr.purpose,
    cr.granted,
    cr.jurisdiction,
    cr.policy_version,
    cr.consent_ip,
    cr.biometric_purpose,
    cr.expires_at,
    cr.created_at,
    LAG(cr.granted) OVER (
        PARTITION BY cr.user_id, cr.purpose 
        ORDER BY cr.created_at
    ) AS previous_state
FROM consent_records cr
ORDER BY cr.user_id, cr.purpose, cr.created_at;

-- ==============================================================================
-- 12. SEED DATA
-- ==============================================================================
INSERT INTO users (
    full_name_encrypted, full_name_iv, full_name_auth_tag, full_name_key_id,
    email_hmac,
    password_hash,
    role,
    data_jurisdiction,
    privacy_consent_at, privacy_policy_version
)
SELECT
    'PLACEHOLDER_AES256_ENCRYPTED',
    'PLACEHOLDER_IV_BASE64',
    'PLACEHOLDER_AUTHTAG_BASE64',
    ek.id,
    encode(hmac('rodolfo@brazilrail.com', 'HMAC_SECRET_REPLACE_IN_APP', 'sha256'), 'hex'),
    '$2b$12$K1e52fz.92K9njhBEWEXGWYrkLJl.1V9t2Hj.3WzW1',
    'ADMIN',
    '{BR,CA}',
    CURRENT_TIMESTAMP,
    '2025-06'
FROM encryption_keys ek
WHERE ek.key_alias = 'personal-v1'
LIMIT 1
ON CONFLICT DO NOTHING;

INSERT INTO train_models (model_name, historical_context, is_legendary, engine_sound_url)
VALUES (
    'Big Boy 4014',
    'The world''s largest steam locomotive, built for heavy freight during the golden age of railroads.',
    TRUE,
    'https://cdn.railmaster.com/audio/big_boy_start.mp3'
) ON CONFLICT DO NOTHING;

-- Seed: consentimento inicial do admin (biometria NÃO concedida por padrão)
INSERT INTO consent_records (user_id, purpose, granted, policy_version, jurisdiction, consent_ip)
SELECT id, 'biometric_authentication', FALSE, '2025-06', 'BR', '127.0.0.1'::inet
FROM users WHERE role = 'ADMIN'
LIMIT 1
ON CONFLICT DO NOTHING;

INSERT INTO consent_records (user_id, purpose, granted, policy_version, jurisdiction, consent_ip)
SELECT id, 'location_tracking', TRUE, '2025-06', 'BR', '127.0.0.1'::inet
FROM users WHERE role = 'ADMIN'
LIMIT 1
ON CONFLICT DO NOTHING;