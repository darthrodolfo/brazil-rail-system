# Brazil Rail System — Redis Schema Reference
# Estruturas de dados e convenções de chave
# Não é um script executável — é documentação de referência
# Cada backend vai implementar essas operações na sua linguagem

## Conexão
# Host: localhost
# Porta: 6380
# Senha: rail_redis_007
# DATABASE_REDIS_URL=redis://:rail_redis_007@localhost:6380

## Convenção de chaves: namespace:identificador

# ============================================================
# 1. SESSION / JWT
# Tipo: Hash
# Chave: session:{userId}
# TTL: 86400 (24 horas)
# ============================================================
# HSET session:uuid-do-user
#   jwt         "eyJhbGc..."
#   role        "ADMIN"
#   username    "rail_admin"
#   last_seen   "2025-01-15T10:30:00Z"
#   ip          "192.168.1.1"
# EXPIRE session:uuid-do-user 86400

# ============================================================
# 2. JWT BLACKLIST (logout / invalidar token)
# Tipo: String com TTL igual ao tempo restante do token
# Chave: blacklist:jwt:{jti}   (jti = JWT ID claim)
# Valor: "revoked"
# TTL: segundos restantes até expiração do token original
# ============================================================
# SET blacklist:jwt:token-uuid "revoked" EX 3600
# Ao autenticar: verificar se jti está na blacklist

# ============================================================
# 3. CACHE DE LISTAGEM DE TRENS
# Tipo: String (JSON serializado)
# Chave: cache:trains:list
# TTL: 60 segundos
# Invalida quando: qualquer CREATE, UPDATE ou DELETE em train_models
# ============================================================
# SET cache:trains:list '[{"id":"...","model_name":"Big Boy",...}]' EX 60

# ============================================================
# 4. CACHE DE DETALHE DE TREM
# Tipo: String (JSON serializado)
# Chave: cache:trains:{trainId}
# TTL: 300 segundos (5 minutos)
# Invalida quando: UPDATE ou DELETE daquele train_id específico
# ============================================================
# SET cache:trains:uuid-do-trem '{"id":"...","model_name":"Big Boy",...}' EX 300

# ============================================================
# 5. RATE LIMITING (sliding window)
# Tipo: Sorted Set
# Chave: ratelimit:{ip}  ou  ratelimit:user:{userId}
# Score: timestamp em milliseconds
# Janela: 60 segundos, máximo 100 requests por IP
# ============================================================
# Algoritmo sliding window:
#   1. ZADD ratelimit:127.0.0.1 <now_ms> <now_ms>
#   2. ZREMRANGEBYSCORE ratelimit:127.0.0.1 0 <now_ms - 60000>
#   3. count = ZCARD ratelimit:127.0.0.1
#   4. EXPIRE ratelimit:127.0.0.1 60
#   5. if count > 100 → 429 Too Many Requests

# ============================================================
# 6. LOGIN ATTEMPT COUNTER (brute force protection)
# Tipo: String com INCR + TTL
# Chave: loginattempts:{email_hash}
# TTL: 900 segundos (15 minutos)
# Máximo: 5 tentativas antes de lockout
# ============================================================
# INCR loginattempts:hash-do-email
# EXPIRE loginattempts:hash-do-email 900
# GET loginattempts:hash-do-email → se >= 5, bloqueia