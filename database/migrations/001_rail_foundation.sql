-- ==============================================================================
-- BRAZIL RAIL SYSTEM — Migration 001: Foundation
-- PostgreSQL: Fonte da verdade — CRUD completo de users + train_models
-- ==============================================================================
-- O que cada banco faz neste projeto:
--
--   PostgreSQL  → Dados estruturados, relacionamentos, fonte da verdade
--                 CRUD completo de users e train_models
--                 Tipos variados: UUID, TEXT, JSONB, BYTEA, DECIMAL,
--                 BOOLEAN, TIMESTAMPTZ, INET, arrays, enums
--
--   Redis       → NÃO é banco primário — é especialista em:
--                 • Session/JWT do usuário logado
--                 • Cache de listagem de trens (TTL 5min)
--                 • Rate limiting por IP/usuário (sliding window)
--                 Estruturas: String (JWT), Hash (session), 
--                 Sorted Set (rate limit), List (recent views)
--
--   MongoDB     → NÃO duplica o PostgreSQL — é especialista em:
--                 • Histórico de edições de train_models (documentos que mudam)
--                 • Activity log de usuários (volume alto, schema flexível)
--                 Collections: train_edit_history, user_activity_log
-- ==============================================================================

-- ==============================================================================
-- 0. EXTENSÕES
-- ==============================================================================
CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- gen_random_uuid(), crypt(), hmac()
CREATE EXTENSION IF NOT EXISTS "pg_trgm";   -- busca fuzzy ILIKE com índice (trigramas)

-- ==============================================================================
-- 1. ENUMS
-- Objetivo de treino: cada stack vai implementar esses enums de forma diferente
-- .NET → enum C# | Go → iota const | Python → Enum class | Java → enum | etc.
-- ==============================================================================
DO $$
BEGIN
    -- Perfil de acesso do usuário
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN
        CREATE TYPE user_role AS ENUM (
            'ADMIN',        -- acesso total: CRUD tudo
            'OPERATOR',     -- pode criar e editar train_models
            'HISTORIAN',    -- somente leitura + pode adicionar historical_context
            'GUEST'         -- somente leitura
        );
    END IF;

    -- Status do modelo de trem
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'train_status') THEN
        CREATE TYPE train_status AS ENUM (
            'ACTIVE',       -- em operação comercial
            'MAINTENANCE',  -- em manutenção
            'RETIRED',      -- aposentado de operação
            'MUSEUM_PIECE', -- peça de museu histórico
            'PROTOTYPE'     -- protótipo / nunca entrou em serviço
        );
    END IF;

    -- Tipo de tração — range de valores fixos, ideal para ensinar enums
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'traction_type') THEN
        CREATE TYPE traction_type AS ENUM (
            'STEAM',        -- vapor
            'DIESEL',       -- diesel
            'ELECTRIC',     -- elétrico (pantógrafo ou terceiro trilho)
            'HYBRID',       -- diesel-elétrico
            'HYDROGEN',     -- célula de hidrogênio
            'MAGLEV'        -- levitação magnética
        );
    END IF;

    -- Bitola ferroviária — padrão técnico real
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'track_gauge') THEN
        CREATE TYPE track_gauge AS ENUM (
            'NARROW',       -- 1000mm — bitola métrica, padrão histórico BR
            'STANDARD',     -- 1435mm — padrão Stephenson, Europa/EUA/China
            'BROAD',        -- 1600mm — Irlanda, Brasil (algumas linhas)
            'IBERIAN',      -- 1668mm — Espanha, Portugal
            'DUAL'          -- duas bitolas no mesmo trilho
        );
    END IF;
END $$;

-- ==============================================================================
-- 2. USERS
-- Objetivo de treino por stack:
--   - Autenticação (hash de senha, JWT)
--   - Upload de avatar (url + mimetype + tamanho)
--   - Tipos variados: UUID, TEXT, INET, BOOLEAN, TIMESTAMPTZ, array
--   - Hash HMAC para busca segura por email
-- ==============================================================================
CREATE TABLE IF NOT EXISTS users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- ── IDENTIDADE ──────────────────────────────────────────────────────────
    username        VARCHAR(50)  UNIQUE NOT NULL,   -- login único, imutável após criação
    display_name    VARCHAR(100) NOT NULL,           -- nome exibido na UI (editável)
    email           VARCHAR(150) UNIQUE NOT NULL,    -- email em claro (simplificado)
    
    -- ── AUTENTICAÇÃO ────────────────────────────────────────────────────────
    password_hash   TEXT NOT NULL,
    -- bcrypt com rounds >= 12
    -- Treino: cada stack usa sua biblioteca bcrypt nativa
    -- Node: bcryptjs | Python: passlib | Go: golang.org/x/crypto/bcrypt
    -- Java: spring-security-crypto | .NET: BCrypt.Net-Next

    -- ── AVATAR / UPLOAD ─────────────────────────────────────────────────────
    -- Treino: upload de arquivo em cada stack (multipart/form-data)
    -- Storage: local em dev, S3-compatible em produção
    avatar_url      VARCHAR(500),                   -- URL pública ou path relativo
    avatar_mime     VARCHAR(50),                    -- 'image/jpeg' | 'image/png' | 'image/webp'
    avatar_size_kb  INTEGER,                        -- tamanho em KB (para UI mostrar)

    -- ── PERFIL EDITÁVEL ─────────────────────────────────────────────────────
    bio             TEXT,                           -- texto livre, até ~2000 chars
    location        VARCHAR(100),                   -- cidade/país, texto livre
    website_url     VARCHAR(500),                   -- URL do site pessoal/portfolio
    
    -- ── PREFERÊNCIAS (JSONB) ─────────────────────────────────────────────────
    -- Treino: como cada stack lida com JSONB (leitura, escrita, query por campo)
    -- Exemplo: {"theme": "dark", "language": "pt-BR", "notifications": true}
    preferences     JSONB DEFAULT '{}',

    -- ── CONTROLE DE ACESSO ──────────────────────────────────────────────────
    role            user_role DEFAULT 'GUEST',
    is_active       BOOLEAN DEFAULT TRUE,
    
    -- ── SEGURANÇA / SESSION ──────────────────────────────────────────────────
    -- Treino: como invalidar tokens JWT via Redis
    -- Quando last_password_change > token.iat → token inválido
    last_password_change TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    last_login_at   TIMESTAMP WITH TIME ZONE,
    last_login_ip   INET,                           -- tipo INET nativo do Postgres
    failed_login_attempts INTEGER DEFAULT 0,        -- para rate limiting no app
    locked_until    TIMESTAMP WITH TIME ZONE,       -- lockout temporário

    -- ── METADADOS ───────────────────────────────────────────────────────────
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Índices de users
CREATE INDEX IF NOT EXISTS idx_users_email     ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_username  ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_role      ON users(role);
-- Índice trigrama para busca fuzzy por display_name (pg_trgm)
-- Treino: mostra como busca full-text funciona no Postgres
CREATE INDEX IF NOT EXISTS idx_users_name_trgm ON users USING gin(display_name gin_trgm_ops);

-- ==============================================================================
-- 3. TRAIN_MODELS
-- Objetivo de treino por stack:
--   - CRUD completo da entidade principal
--   - Upload de múltiplos tipos de mídia (imagem, vídeo, áudio)
--   - Tipos ricos: DECIMAL, INTEGER, BOOLEAN, JSONB, BYTEA, arrays, enums
--   - Geodados: lat/lng de fabricação e rotas históricas
--   - Relacionamento FK com users (criado_por)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS train_models (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- ── IDENTIFICAÇÃO ────────────────────────────────────────────────────────
    model_name      VARCHAR(100) NOT NULL,          -- "Big Boy 4014", "TGV Duplex"
    manufacturer    VARCHAR(100),                   -- "Union Pacific", "Alstom"
    country_origin  VARCHAR(60),                    -- "United States", "France", "Brazil"
    year_introduced INTEGER,                        -- 1941, 1994, 2023
    year_retired    INTEGER,                        -- NULL se ainda ativo

    -- ── CLASSIFICAÇÃO ────────────────────────────────────────────────────────
    status          train_status DEFAULT 'ACTIVE',
    traction        traction_type,
    gauge           track_gauge DEFAULT 'STANDARD',
    is_legendary    BOOLEAN DEFAULT FALSE,          -- destaque especial na UI

    -- ── DADOS TÉCNICOS (tipos numéricos variados) ─────────────────────────────
    -- Treino: DECIMAL vs INTEGER vs FLOAT em cada stack e ORM
    max_speed_kmh   INTEGER,                        -- velocidade máxima (km/h)
    power_kw        INTEGER,                        -- potência total (kW)
    weight_tonnes   DECIMAL(8,2),                   -- peso em toneladas (ex: 548.25)
    length_meters   DECIMAL(6,2),                   -- comprimento (ex: 40.50)
    passenger_capacity INTEGER,                     -- passageiros (NULL para carga)
    
    -- ── CONTEÚDO DESCRITIVO ──────────────────────────────────────────────────
    description     TEXT,                           -- resumo curto (para cards)
    historical_context TEXT,                        -- texto longo histórico (para detail page)
    fun_facts       TEXT[],                         -- array de strings
    -- Treino: como cada stack/ORM lida com arrays nativos do Postgres
    -- Exemplo: {"Primeiro trem a atingir 200km/h", "Operou por 50 anos ininterruptos"}

    -- ── MÍDIAS (upload/download em cada stack) ────────────────────────────────
    -- Treino principal: multipart upload, storage, streaming de áudio/vídeo
    
    -- Imagem principal (obrigatória para a UI)
    main_image_url  VARCHAR(500),
    main_image_mime VARCHAR(50),                    -- 'image/jpeg' | 'image/webp' | 'image/png'
    main_image_size_kb INTEGER,

    -- Galeria de imagens (array de URLs)
    gallery_urls    TEXT[],
    -- Treino: inserir/atualizar arrays, query com ANY(), @> operator

    -- Vídeo técnico/histórico
    video_url       VARCHAR(500),
    video_mime      VARCHAR(50),                    -- 'video/mp4' | 'video/webm'
    video_duration_sec INTEGER,                     -- duração em segundos
    video_size_mb   DECIMAL(6,2),

    -- Áudio (som do motor — feature única e memorável)
    engine_sound_url  VARCHAR(500),
    engine_sound_mime VARCHAR(50),                  -- 'audio/mpeg' | 'audio/wav' | 'audio/ogg'
    engine_sound_duration_sec INTEGER,

    -- Documento técnico (PDF de especificações)
    -- Treino: upload de PDF + download com Content-Disposition header
    spec_sheet_url  VARCHAR(500),
    spec_sheet_size_kb INTEGER,

    -- ── GEODADOS (lat/lng de origem) ──────────────────────────────────────────
    -- Treino: tipos DECIMAL para geo, como cada ORM mapeia, como exibir no front
    -- Fábrica de origem — onde foi construído
    factory_lat     DECIMAL(9,6),                   -- ex: -23.548943
    factory_lng     DECIMAL(9,6),                   -- ex: -46.638818
    factory_city    VARCHAR(100),                   -- "Schenectady", "São Paulo"
    
    -- Rota histórica principal (array de coordenadas como JSONB)
    -- Treino: JSONB com estrutura aninhada, indexação GIN
    -- Exemplo: [{"lat": -23.5, "lng": -46.6, "station": "Luz"}, ...]
    historical_route JSONB DEFAULT '[]',

    -- ── METADADOS FLEXÍVEIS (JSONB) ───────────────────────────────────────────
    -- Treino: JSONB para campos que variam por tipo de trem
    -- Steam: {"boiler_pressure_psi": 300, "wheel_arrangement": "4-8-8-4"}
    -- Maglev: {"levitation_height_mm": 10, "guideway_type": "T-shaped"}
    -- Electric: {"voltage_v": 25000, "frequency_hz": 50}
    technical_specs JSONB DEFAULT '{}',

    -- ── RELACIONAMENTO ────────────────────────────────────────────────────────
    created_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    -- Treino: JOIN em cada stack, como ORMs carregam relacionamentos (eager/lazy)

    -- ── METADADOS ───────────────────────────────────────────────────────────
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Índices de train_models
CREATE INDEX IF NOT EXISTS idx_trains_status      ON train_models(status);
CREATE INDEX IF NOT EXISTS idx_trains_traction    ON train_models(traction);
CREATE INDEX IF NOT EXISTS idx_trains_country     ON train_models(country_origin);
CREATE INDEX IF NOT EXISTS idx_trains_legendary   ON train_models(is_legendary) WHERE is_legendary = TRUE;
CREATE INDEX IF NOT EXISTS idx_trains_year        ON train_models(year_introduced);
CREATE INDEX IF NOT EXISTS idx_trains_created_by  ON train_models(created_by);
-- Busca fuzzy por nome do modelo
CREATE INDEX IF NOT EXISTS idx_trains_name_trgm   ON train_models USING gin(model_name gin_trgm_ops);
-- Índice GIN para queries em JSONB (technical_specs e historical_route)
CREATE INDEX IF NOT EXISTS idx_trains_specs_gin   ON train_models USING gin(technical_specs);
CREATE INDEX IF NOT EXISTS idx_trains_route_gin   ON train_models USING gin(historical_route);
-- Índice geográfico simples (sem PostGIS por ora)
CREATE INDEX IF NOT EXISTS idx_trains_geo         ON train_models(factory_lat, factory_lng)
    WHERE factory_lat IS NOT NULL AND factory_lng IS NOT NULL;

-- ==============================================================================
-- 4. TRIGGER — updated_at automático
-- ==============================================================================
CREATE OR REPLACE FUNCTION fn_update_updated_at()
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
            FOR EACH ROW EXECUTE FUNCTION fn_update_updated_at();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_train_models_updated_at') THEN
        CREATE TRIGGER trg_train_models_updated_at
            BEFORE UPDATE ON train_models
            FOR EACH ROW EXECUTE FUNCTION fn_update_updated_at();
    END IF;
END $$;

-- ==============================================================================
-- 5. SEEDS — dados realistas para treino imediato
-- ==============================================================================

-- Usuário admin (senha: Admin@2025! — hash bcrypt rounds=12)
INSERT INTO users (username, display_name, email, password_hash, role, bio, location, preferences)
VALUES (
    'rail_admin',
    'Rail System Admin',
    'admin@brazilrail.com',
    '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TiGc.0B4GrD5vQPz/GNIG7.WZWGO',
    'ADMIN',
    'System administrator of the Brazil Rail System platform.',
    'São Paulo, Brazil',
    '{"theme": "dark", "language": "pt-BR", "notifications": true}'
) ON CONFLICT (email) DO NOTHING;

-- Usuário operator
INSERT INTO users (username, display_name, email, password_hash, role, bio, location)
VALUES (
    'historian_one',
    'Maria Ferroviária',
    'maria@brazilrail.com',
    '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TiGc.0B4GrD5vQPz/GNIG7.WZWGO',
    'HISTORIAN',
    'Ferroviária apaixonada pela história das locomotivas brasileiras.',
    'Jundiaí, SP, Brazil'
) ON CONFLICT (email) DO NOTHING;

-- Trem 1: Big Boy 4014 — icônico, muitos campos preenchidos
INSERT INTO train_models (
    model_name, manufacturer, country_origin, year_introduced, year_retired,
    status, traction, gauge, is_legendary,
    max_speed_kmh, power_kw, weight_tonnes, length_meters,
    description, historical_context,
    fun_facts,
    engine_sound_url, engine_sound_mime, engine_sound_duration_sec,
    factory_lat, factory_lng, factory_city,
    technical_specs,
    created_by
)
SELECT
    'Big Boy 4014',
    'American Locomotive Company (ALCO)',
    'United States',
    1941, 1959,
    'MUSEUM_PIECE', 'STEAM', 'STANDARD', TRUE,
    112, 4000, 548, 40,
    'The world''s largest and most powerful steam locomotive ever built.',
    'Built for Union Pacific Railroad to haul heavy freight over the Wasatch Mountains in Utah. Only 25 were ever made. The 4014 was restored to operation in 2019 after 60 years of static display.',
    ARRAY[
        'At 548 tonnes, it''s heavier than a fully loaded Boeing 747',
        'The name "Big Boy" was scrawled by a worker during construction',
        'Consumed 22 tonnes of coal and 75,000 liters of water per trip',
        'The only Big Boy still operational in the world'
    ],
    'https://storage.brazilrail.com/audio/big_boy_start.mp3',
    'audio/mpeg', 45,
    41.2565, -111.0842, 'Ogden, Utah',
    '{"wheel_arrangement": "4-8-8-4", "boiler_pressure_psi": 300, "cylinder_count": 4, "tractive_effort_lbf": 135375}',
    u.id
FROM users u WHERE u.username = 'rail_admin' LIMIT 1
ON CONFLICT DO NOTHING;

-- Trem 2: TGV Duplex — velocidade, europeu
INSERT INTO train_models (
    model_name, manufacturer, country_origin, year_introduced,
    status, traction, gauge, is_legendary,
    max_speed_kmh, power_kw, weight_tonnes, length_meters, passenger_capacity,
    description, historical_context,
    fun_facts,
    factory_lat, factory_lng, factory_city,
    technical_specs,
    created_by
)
SELECT
    'TGV Duplex',
    'Alstom',
    'France',
    1996,
    'ACTIVE', 'ELECTRIC', 'STANDARD', TRUE,
    320, 8800, 380, 200, 508,
    'Double-deck high-speed train, the backbone of French rail network.',
    'Developed to increase passenger capacity on busy Paris routes without adding more trains. The double-deck design was revolutionary in high-speed rail.',
    ARRAY[
        'Can carry 508 passengers at 320 km/h',
        'Uses regenerative braking to feed electricity back to the grid',
        'The TGV holds the wheel-on-rail speed record: 574.8 km/h'
    ],
    47.3215, 5.0415, 'Dijon, France',
    '{"voltage_v": 25000, "frequency_hz": 50, "bogies": "articulated", "pantograph": "single-arm"}',
    u.id
FROM users u WHERE u.username = 'rail_admin' LIMIT 1
ON CONFLICT DO NOTHING;

-- Trem 3: Maria Fumaça (E.F. Mogiana) — brasileiro, histórico
INSERT INTO train_models (
    model_name, manufacturer, country_origin, year_introduced, year_retired,
    status, traction, gauge, is_legendary,
    max_speed_kmh, weight_tonnes, length_meters,
    description, historical_context,
    fun_facts,
    factory_lat, factory_lng, factory_city,
    technical_specs,
    created_by
)
SELECT
    'Maria Fumaça — E.F. Mogiana',
    'Baldwin Locomotive Works',
    'Brazil',
    1896, 1975,
    'MUSEUM_PIECE', 'STEAM', 'NARROW', TRUE,
    60, 45, 12,
    'Iconic Brazilian steam locomotive that shaped the coffee-era economy of São Paulo state.',
    'The Estrada de Ferro Mogiana was the backbone of São Paulo''s coffee economy in the late 19th and early 20th centuries. The Maria Fumaça (Smoky Mary) became a cultural symbol of Brazilian industrial heritage. Today, a restored unit operates tourist excursions between Campinas and Jaguariúna.',
    ARRAY[
        'The term "Maria Fumaça" became generic for any steam train in Brazil',
        'The narrow gauge (1000mm) was chosen to reduce construction costs in rugged terrain',
        'Transported 60% of Brazil''s coffee exports at its peak',
        'A restored unit still operates tourist rides in São Paulo state'
    ],
    -22.9068, -47.0626, 'Campinas, SP, Brazil',
    '{"wheel_arrangement": "2-8-0", "boiler_pressure_psi": 180, "fuel": "wood_or_coal", "gauge_mm": 1000}',
    u.id
FROM users u WHERE u.username = 'rail_admin' LIMIT 1
ON CONFLICT DO NOTHING;

-- Trem 4: Maglev SCMaglev — tecnologia de ponta para testar campos futuristas
INSERT INTO train_models (
    model_name, manufacturer, country_origin, year_introduced,
    status, traction, gauge, is_legendary,
    max_speed_kmh, power_kw, weight_tonnes, length_meters, passenger_capacity,
    description, historical_context,
    fun_facts,
    factory_lat, factory_lng, factory_city,
    technical_specs,
    created_by
)
SELECT
    'SCMaglev L0 Series',
    'Central Japan Railway (JR Central)',
    'Japan',
    2013,
    'PROTOTYPE', 'MAGLEV', 'DUAL', TRUE,
    603, 30000, 325, 150, 900,
    'World''s fastest train, holding the absolute speed record of 603 km/h.',
    'Japan''s superconducting maglev uses liquid helium-cooled magnets to levitate 10mm above the guideway. The Chuo Shinkansen line between Tokyo and Osaka is under construction, targeting commercial operation in 2027.',
    ARRAY[
        'Holds the world speed record: 603 km/h achieved April 21, 2015',
        'Levitates using superconducting magnets cooled to -269°C',
        'Tokyo to Osaka (500km) will take only 67 minutes',
        'No wheels touch the track — zero mechanical friction at speed'
    ],
    35.1815, 136.9066, 'Nagoya, Japan',
    '{"levitation_height_mm": 10, "guideway_type": "U-shaped", "cooling": "liquid_helium", "superconducting": true, "frequency_hz": 0, "propulsion": "linear_induction_motor"}',
    u.id
FROM users u WHERE u.username = 'rail_admin' LIMIT 1
ON CONFLICT DO NOTHING;

-- ==============================================================================
-- 6. COMENTÁRIOS PARA MONGODB E REDIS
-- (Não são tabelas SQL — são schemas de documento/estruturas de chave)
-- Documentados aqui para referência cruzada com os outros bancos
-- ==============================================================================

COMMENT ON TABLE users IS
'PostgreSQL: fonte da verdade para autenticação e perfil.
Redis: hash session:{userId} com campos {jwt, role, last_seen}.
MongoDB: collection user_activity_log — eventos de navegação, uploads, buscas.';

COMMENT ON TABLE train_models IS
'PostgreSQL: fonte da verdade para dados estruturados dos trens.
Redis: string cache:train:{id} (JSON serializado, TTL 300s) + set cache:train:list (TTL 60s).
MongoDB: collection train_edit_history — cada UPDATE gera um documento com snapshot antes/depois.';

COMMENT ON COLUMN train_models.technical_specs IS
'JSONB flexível por tipo de tração.
Steam: {wheel_arrangement, boiler_pressure_psi, tractive_effort_lbf}
Electric: {voltage_v, frequency_hz, pantograph}
Maglev: {levitation_height_mm, guideway_type, superconducting}
Diesel: {engine_model, cylinders, transmission}';

COMMENT ON COLUMN train_models.historical_route IS
'Array de waypoints GeoJSON-like.
Formato: [{"lat": -23.5, "lng": -46.6, "station": "Luz", "year": 1900}, ...]
Indexado com GIN para queries como: historical_route @> ''[{"station": "Luz"}]''::jsonb';

COMMENT ON COLUMN users.preferences IS
'JSONB de preferências do usuário.
Exemplo: {"theme": "dark", "language": "pt-BR", "notifications": true, "items_per_page": 20}';