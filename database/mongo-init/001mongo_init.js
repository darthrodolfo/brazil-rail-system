// ============================================================
// Brazil Rail System — MongoDB Init Script
// Executado automaticamente na primeira inicialização
// ============================================================
// Papel do MongoDB neste projeto:
//   NÃO duplica dados do PostgreSQL
//   Especialista em: documentos flexíveis, histórico, logs de volume alto
// Collections:
//   train_edit_history  → snapshot before/after de cada UPDATE em train_models
//   user_activity_log   → eventos de navegação, upload, busca, login
// ============================================================

// Selecionar (ou criar) o database do projeto
const db = db.getSiblingDB('brazil_rail_mongo');

// ============================================================
// 1. Criar usuário da aplicação (não usar o root em produção)
// ============================================================
db.createUser({
  user: 'rail_app',
  pwd:  'rail_app_007',
  roles: [
    { role: 'readWrite', db: 'brazil_rail_mongo' }
  ]
});

// ============================================================
// 2. Collection: train_edit_history
// Armazena histórico de edições de train_models
// Cada UPDATE no PostgreSQL gera um documento aqui
// ============================================================
db.createCollection('train_edit_history', {
  validator: {
    $jsonSchema: {
      bsonType: 'object',
      required: ['train_id', 'edited_by', 'edited_at', 'changes'],
      properties: {
        // ID do trem no PostgreSQL (referência cruzada)
        train_id: {
          bsonType: 'string',
          description: 'UUID do train_model no PostgreSQL'
        },
        // Quem editou
        edited_by: {
          bsonType: 'string',
          description: 'UUID do user no PostgreSQL'
        },
        edited_at: {
          bsonType: 'date'
        },
        // Campos alterados com valor antes e depois
        // Exemplo:
        // { "model_name": { "before": "Big Boy", "after": "Big Boy 4014" },
        //   "status": { "before": "ACTIVE", "after": "MUSEUM_PIECE" } }
        changes: {
          bsonType: 'object',
          description: 'Campos alterados com before/after'
        },
        // Snapshot completo ANTES da edição (para rollback/auditoria)
        snapshot_before: {
          bsonType: 'object',
          description: 'Estado completo do documento antes da edição'
        },
        // Metadados da requisição
        request_id: { bsonType: 'string' },
        ip_address: { bsonType: 'string' },
        user_agent: { bsonType: 'string' }
      }
    }
  }
});

// Índices para queries frequentes
db.train_edit_history.createIndex({ train_id: 1, edited_at: -1 });
db.train_edit_history.createIndex({ edited_by: 1 });
db.train_edit_history.createIndex({ edited_at: -1 });

// ============================================================
// 3. Collection: user_activity_log
// Eventos de uso do sistema — volume alto, schema flexível
// Cada stack insere aqui ao detectar eventos relevantes
// ============================================================
db.createCollection('user_activity_log', {
  // TTL index: documentos expiram após 90 dias automaticamente
  // MongoDB gerencia a limpeza — zero código adicional
});

// Índices para user_activity_log
db.user_activity_log.createIndex({ user_id: 1, occurred_at: -1 });
db.user_activity_log.createIndex({ event_type: 1 });
db.user_activity_log.createIndex(
  { occurred_at: 1 },
  { expireAfterSeconds: 7776000 } // 90 dias — TTL automático
);

// ============================================================
// 4. Seeds de exemplo — um documento de cada tipo
// ============================================================

// Exemplo de registro em train_edit_history
db.train_edit_history.insertOne({
  train_id:    '00000000-0000-0000-0000-000000000001', // placeholder UUID
  edited_by:   '00000000-0000-0000-0000-000000000099',
  edited_at:   new Date(),
  changes: {
    status: {
      before: 'ACTIVE',
      after:  'MUSEUM_PIECE'
    },
    historical_context: {
      before: null,
      after:  'Restored in 2019 after 60 years of static display.'
    }
  },
  snapshot_before: {
    model_name: 'Big Boy 4014',
    status:     'ACTIVE',
    traction:   'STEAM',
    is_legendary: true
  },
  request_id: 'seed-request-001',
  ip_address: '127.0.0.1',
  user_agent: 'SeedScript/1.0'
});

// Exemplos de registros em user_activity_log
db.user_activity_log.insertMany([
  {
    user_id:    '00000000-0000-0000-0000-000000000099',
    event_type: 'LOGIN',
    occurred_at: new Date(),
    metadata: {
      ip_address: '127.0.0.1',
      user_agent: 'Mozilla/5.0',
      success: true
    }
  },
  {
    user_id:    '00000000-0000-0000-0000-000000000099',
    event_type: 'TRAIN_VIEWED',
    occurred_at: new Date(),
    metadata: {
      train_id:   '00000000-0000-0000-0000-000000000001',
      train_name: 'Big Boy 4014',
      duration_sec: 45
    }
  },
  {
    user_id:    '00000000-0000-0000-0000-000000000099',
    event_type: 'SEARCH',
    occurred_at: new Date(),
    metadata: {
      query:        'steam locomotive',
      results_count: 3,
      duration_ms:  120
    }
  },
  {
    user_id:    '00000000-0000-0000-0000-000000000099',
    event_type: 'MEDIA_UPLOADED',
    occurred_at: new Date(),
    metadata: {
      train_id:  '00000000-0000-0000-0000-000000000001',
      file_type: 'audio/mpeg',
      file_size_kb: 2048,
      field:     'engine_sound_url'
    }
  }
]);

print('✅ MongoDB brazil_rail_mongo inicializado com sucesso!');
print('   Collections: train_edit_history, user_activity_log');
print('   User app criado: rail_app');