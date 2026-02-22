-- ==============================================================================
-- 1. EXTENSÕES E ENUMS
-- ==============================================================================
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'train_status') THEN
        CREATE TYPE train_status AS ENUM ('ACTIVE', 'MAINTENANCE', 'OUT_OF_SERVICE', 'MUSEUM_PIECE');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN
        CREATE TYPE user_role AS ENUM ('ADMIN', 'OPERATOR', 'MAINTENANCE', 'HISTORIAN');
    END IF;
END $$;

-- ==============================================================================
-- 2. TABELA DE USUÁRIOS (Foco em LGPD e Biometria)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Dados Sensíveis (LGPD) - Criptografia em nível de aplicação (Node/C#)
    full_name_encrypted TEXT NOT NULL, 
    email_hash TEXT UNIQUE NOT NULL,    -- Deterministico para busca rápida
    document_id_encrypted TEXT,         -- CPF/Passaporte criptografado
    
    -- Autenticação Avançada
    password_hash TEXT NOT NULL,
    biometric_public_key TEXT,          -- Chave pública (FIDO2/WebAuthn)
    face_signature_vector BYTEA,        -- Vetor numérico para simulação de IA
    
    role user_role DEFAULT 'OPERATOR',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ==============================================================================
-- 3. TRAIN_MODELS (Mídias e História)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS train_models (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    model_name VARCHAR(100) NOT NULL,
    
    -- Multimídia Rica
    main_image_url VARCHAR(255),
    technical_video_url VARCHAR(255),
    engine_sound_url VARCHAR(255),      
    
    -- História e Metadados
    historical_context TEXT,
    is_legendary BOOLEAN DEFAULT FALSE,
    
    -- Metadados dinâmicos
    metadata JSONB DEFAULT '{}', 
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ==============================================================================
-- 4. TRAIN_UNITS (Geolocalização e Telemetria IoT)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS train_units (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    serial_number VARCHAR(50) UNIQUE NOT NULL,
    model_id UUID REFERENCES train_models(id),
    
    -- IoT e Geo (Pronto para PostGIS)
    current_lat DECIMAL(9,6),
    current_lng DECIMAL(9,6),
    altitude_meters INTEGER,
    current_speed_kmh INTEGER,
    
    -- Auditoria
    last_operator_id UUID REFERENCES users(id),
    current_status train_status DEFAULT 'ACTIVE',
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ==============================================================================
-- 5. SEED DATA (Simulação de Segurança)
-- ==============================================================================
INSERT INTO users (full_name_encrypted, email_hash, password_hash, role)
VALUES (
    'ENCRYPTED_DATA_AES256_RODOLFO', 
    encode(digest('rodolfo@brazilrail.com', 'sha256'), 'hex'),
    '$2b$12$K1e52fz.92K9njhBEWEXGWYrkLJl.1V9t2Hj.3WzW1', -- Simulação Hash Bcrypt
    'ADMIN'
);

INSERT INTO train_models (model_name, historical_context, is_legendary, engine_sound_url)
VALUES (
    'Big Boy 4014', 
    'The world''s largest steam locomotive, built for heavy freight during the golden age of railroads.', 
    TRUE,
    'https://cdn.railmaster.com/audio/big_boy_start.mp3'
);