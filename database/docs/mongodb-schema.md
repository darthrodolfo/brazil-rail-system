# MongoDB Schema — Brazil Rail System

## Conexão
```
Host:     localhost
Porta:    27018  ← não é 27017
Database: brazil_rail_mongo
App User: rail_app / rail_app_007
URL:      mongodb://rail_app:rail_app_007@localhost:27018/brazil_rail_mongo
```

## Papel do MongoDB neste projeto
MongoDB NÃO duplica dados do PostgreSQL.
Especialista em: documentos flexíveis, histórico de mudanças, logs de volume alto.
Regra: se o dado tem schema fixo e precisa de JOIN → PostgreSQL.
         Se o dado muda de shape, tem volume alto ou é histórico → MongoDB.

---

## Collection: train_edit_history

### Propósito
Registra cada UPDATE feito em train_models no PostgreSQL.
Permite ver o histórico completo de edições de qualquer trem.
O campo `changes` varia dependendo do que foi editado — schema flexível é o ponto forte.

### Schema do documento
```json
{
  "_id": "ObjectId (gerado automaticamente)",
  "train_id":        "UUID string — ID do train_model no PostgreSQL",
  "edited_by":       "UUID string — ID do user no PostgreSQL",
  "edited_at":       "ISODate",
  "changes": {
    "campo_alterado": {
      "before": "valor anterior",
      "after":  "valor novo"
    }
  },
  "snapshot_before": {
    "model_name":  "Big Boy 4014",
    "status":      "ACTIVE",
    "traction":    "STEAM",
    "is_legendary": true
  },
  "request_id":  "UUID da requisição HTTP",
  "ip_address":  "string",
  "user_agent":  "string"
}
```

### Exemplo real
```json
{
  "train_id":  "a1b2c3d4-...",
  "edited_by": "f9e8d7c6-...",
  "edited_at": "2025-06-15T14:30:00Z",
  "changes": {
    "status": {
      "before": "ACTIVE",
      "after":  "MUSEUM_PIECE"
    },
    "historical_context": {
      "before": null,
      "after":  "Restored in 2019 after 60 years of static display."
    }
  },
  "snapshot_before": {
    "model_name":       "Big Boy 4014",
    "status":           "ACTIVE",
    "traction":         "STEAM",
    "max_speed_kmh":    112,
    "is_legendary":     true
  },
  "request_id": "req-uuid-here",
  "ip_address": "192.168.1.1",
  "user_agent": "Mozilla/5.0 ..."
}
```

### Índices
```
{ train_id: 1, edited_at: -1 }   ← query: histórico de um trem
{ edited_by: 1 }                  ← query: edições de um usuário
{ edited_at: -1 }                 ← query: edições recentes globais
```

### Queries frequentes
```javascript
// Histórico completo de um trem (mais recente primeiro)
db.train_edit_history.find(
  { train_id: "uuid-do-trem" }
).sort({ edited_at: -1 })

// Últimas 10 edições de qualquer trem
db.train_edit_history.find({})
  .sort({ edited_at: -1 })
  .limit(10)

// Quem editou o campo 'status' de um trem específico
db.train_edit_history.find({
  train_id: "uuid-do-trem",
  "changes.status": { $exists: true }
})
```

---

## Collection: user_activity_log

### Propósito
Eventos de uso da plataforma por usuário.
Volume potencialmente alto — TTL automático de 90 dias.
O campo `metadata` muda de shape por event_type — ideal para MongoDB.

### Event Types e seus metadata

```json
// LOGIN
{
  "user_id":    "UUID string",
  "event_type": "LOGIN",
  "occurred_at": "ISODate",
  "metadata": {
    "ip_address": "192.168.1.1",
    "user_agent": "Mozilla/5.0...",
    "success":    true
  }
}

// LOGIN_FAILED
{
  "user_id":    "UUID string",
  "event_type": "LOGIN_FAILED",
  "occurred_at": "ISODate",
  "metadata": {
    "ip_address":    "192.168.1.1",
    "reason":        "invalid_password",
    "attempt_count": 3
  }
}

// TRAIN_VIEWED
{
  "user_id":    "UUID string",
  "event_type": "TRAIN_VIEWED",
  "occurred_at": "ISODate",
  "metadata": {
    "train_id":     "UUID do trem",
    "train_name":   "Big Boy 4014",
    "duration_sec": 45,
    "referrer":     "search_results"
  }
}

// SEARCH
{
  "user_id":    "UUID string",
  "event_type": "SEARCH",
  "occurred_at": "ISODate",
  "metadata": {
    "query":         "steam locomotive",
    "filters":       { "traction": "STEAM", "status": "MUSEUM_PIECE" },
    "results_count": 3,
    "duration_ms":   120
  }
}

// MEDIA_UPLOADED
{
  "user_id":    "UUID string",
  "event_type": "MEDIA_UPLOADED",
  "occurred_at": "ISODate",
  "metadata": {
    "train_id":    "UUID do trem",
    "field":       "engine_sound_url",
    "file_type":   "audio/mpeg",
    "file_size_kb": 2048,
    "duration_ms": 850
  }
}

// PROFILE_UPDATED
{
  "user_id":    "UUID string",
  "event_type": "PROFILE_UPDATED",
  "occurred_at": "ISODate",
  "metadata": {
    "fields_changed": ["display_name", "bio", "avatar_url"]
  }
}
```

### Índices
```
{ user_id: 1, occurred_at: -1 }   ← query: atividade de um usuário
{ event_type: 1 }                  ← query: todos os eventos de um tipo
{ occurred_at: 1 } com TTL 90 dias ← expira documentos automaticamente
```

### Queries frequentes
```javascript
// Atividade recente de um usuário
db.user_activity_log.find(
  { user_id: "uuid-do-user" }
).sort({ occurred_at: -1 }).limit(20)

// Todos os logins falhados nas últimas 24h
db.user_activity_log.find({
  event_type:  "LOGIN_FAILED",
  occurred_at: { $gte: new Date(Date.now() - 86400000) }
})

// Trens mais visualizados
db.user_activity_log.aggregate([
  { $match: { event_type: "TRAIN_VIEWED" } },
  { $group: { _id: "$metadata.train_id", views: { $sum: 1 } } },
  { $sort: { views: -1 } },
  { $limit: 10 }
])
```

---

## Padrão de inserção em cada backend

```
Quando inserir em train_edit_history:
  → Em qualquer endpoint PUT /train-models/:id
  → DEPOIS de confirmar que o UPDATE no PostgreSQL foi bem-sucedido
  → Nunca antes — MongoDB é complemento, não transação principal

Quando inserir em user_activity_log:
  → LOGIN/LOGIN_FAILED: no endpoint POST /auth/login
  → TRAIN_VIEWED: no endpoint GET /train-models/:id
  → SEARCH: no endpoint GET /train-models?q=...
  → MEDIA_UPLOADED: nos endpoints de upload de mídia
  → PROFILE_UPDATED: no endpoint PUT /users/:id

Tratamento de erro:
  → Falha no MongoDB NUNCA deve retornar erro 500 para o cliente
  → Log o erro internamente + continue
  → MongoDB é auxiliar — PostgreSQL é a fonte da verdade
```