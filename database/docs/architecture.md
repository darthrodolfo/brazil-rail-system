# Architecture & Project Guide — Brazil Rail System

> Este arquivo é lido pelo Cursor AI e GitHub Copilot para entender
> o contexto completo do projeto. Mantenha-o atualizado conforme avança.

---

## O Projeto

Brazil Rail System é um portfólio multi-stack de aprendizado.
O mesmo domínio (users + train_models) implementado em 10 backends,
4 frontends web, 3 desktops e 2 mobile — cada um conectando
PostgreSQL + Redis + MongoDB com Repository Pattern e multi-DB switchable.

**Objetivo profissional:** demonstrar proficiência multi-stack para
o mercado canadense e internacional em entrevistas de nível sênior.

---

## Infraestrutura (Docker — todos os serviços)

| Serviço        | Container                    | Porta   | Credenciais                          |
|----------------|------------------------------|---------|--------------------------------------|
| PostgreSQL 16  | brazil_rail_db_container     | 5434    | rail_admin / rail_password_007       |
| pgAdmin 4      | brazil_rail_pgadmin          | 5051    | admin@brazilrail.com / admin         |
| Redis 7        | brazil_rail_redis            | 6380    | senha: rail_redis_007                |
| MongoDB 7      | brazil_rail_mongo            | 27018   | rail_app / rail_app_007              |
| Mongo Express  | brazil_rail_mongo_express    | 8081    | admin / admin                        |

**Databases:**
- PostgreSQL: `brazil_rail_db`
- MongoDB: `brazil_rail_mongo`

---

## Entidades PostgreSQL

### users
Autenticação, perfil e controle de acesso.
- Auth: `password_hash` (bcrypt rounds>=12), JWT via Redis
- Upload: `avatar_url`, `avatar_mime`, `avatar_size_kb`
- Perfil: `display_name`, `bio`, `location`, `website_url`
- Preferências: `preferences` JSONB
- Role: ENUM → ADMIN | OPERATOR | HISTORIAN | GUEST
- Segurança: `last_login_ip` INET, `locked_until`, `failed_login_attempts`

### train_models
Entidade principal — rica em tipos de dados.
- Classificação: `status`, `traction`, `gauge` (todos ENUMs)
- Técnicos: `max_speed_kmh`, `power_kw`, `weight_tonnes` DECIMAL, `length_meters` DECIMAL
- Arrays nativos: `fun_facts TEXT[]`, `gallery_urls TEXT[]`
- Mídias: imagem principal, galeria, vídeo, áudio (som do motor), PDF spec sheet
- Geodados: `factory_lat/lng` DECIMAL(9,6), `historical_route` JSONB
- Metadados: `technical_specs` JSONB (varia por tipo de tração)
- Relação: `created_by` UUID → users

---

## Papel de cada banco

```
PostgreSQL  → fonte da verdade. CRUD completo. Relacionamentos, índices, triggers.
Redis       → velocidade e estado efêmero.
              session:{userId}, blacklist:jwt:{jti},
              cache:trains:list (TTL 60s), cache:trains:{id} (TTL 300s),
              ratelimit:{ip} sliding window, loginattempts:{hash}
MongoDB     → documentos flexíveis e histórico.
              train_edit_history (snapshot before/after de cada UPDATE)
              user_activity_log (eventos de uso, TTL 90 dias automático)
```

Regra: falha no MongoDB NUNCA retorna erro 500. É auxiliar, não transação principal.

---

## Padrão Arquitetural — Repository Pattern + Factory

Obrigatório em TODAS as stacks:

```
Interface IUserRepository / ITrainModelRepository
    ↓
Implementações: PgRepo | OrmRepo (varia por stack)
    ↓
Factory lê DB_PROVIDER do .env → retorna implementação correta
    ↓
Rotas/Controllers conhecem APENAS a interface
```

`DB_PROVIDER=pg|prisma|drizzle` (Node) — trocar + reiniciar = mesma API, motor diferente.

---

## Roadmap de Fases

### Fase 1 — Minimal / Fast APIs ← EM ANDAMENTO
Mínimo de boilerplate. Rotas diretas. CRUD + upload + Redis + MongoDB.
Cada stack: ~10 endpoints, 3 DB providers, uploads de 4 tipos de mídia.

### Fase 2 — REST APIs estruturadas
Adiciona: JWT auth completo, Swagger/OpenAPI, paginação, filtros,
ordenação, error handling padronizado, middlewares organizados.

### Fase 3 — GraphQL
Adiciona: queries, mutations, subscriptions, dataloader (N+1 fix).
Uma camada GraphQL sobre a mesma base de cada stack.

---

## Backends — 10 stacks

| # | Pasta         | Stack                        | Porta | Status        |
|---|---------------|------------------------------|-------|---------------|
| 1 | api-node/     | Node.js + Fastify + TS       | 8001  | 🔄 Em andamento |
| 2 | api-python/   | Python + FastAPI             | 8002  | ⏳ Aguardando  |
| 3 | api-go/       | Go + Gin ou Fiber            | 8003  | ⏳ Aguardando  |
| 4 | api-dotnet/   | .NET + Minimal API           | 8004  | ⏳ Aguardando  |
| 5 | api-java/     | Java + Javalin → Spring Boot | 8005  | ⏳ Aguardando  |
| 6 | api-kotlin/   | Kotlin + Ktor                | 8006  | ⏳ Aguardando  |
| 7 | api-rust/     | Rust + Axum                  | 8007  | ⏳ Aguardando  |
| 8 | api-php/      | PHP + Slim → Laravel         | 8008  | ⏳ Aguardando  |
| 9 | api-ruby/     | Ruby + Sinatra               | 8009  | ⏳ Aguardando  |

### 2 modos de conexão PostgreSQL por stack

| Stack   | Modo 1 (driver/raw)   | Modo 2 (ORM)           |
|---------|-----------------------|------------------------|
| Node.js | pg (node-postgres)    | Prisma ou Drizzle      |
| Python  | psycopg3              | SQLAlchemy             |
| Go      | pgx + sqlc            | GORM                   |
| .NET    | Dapper / Npgsql raw   | EF Core                |
| Java    | JDBC puro             | Spring Data JPA        |
| Kotlin  | Exposed DSL           | Ktorm                  |
| Rust    | sqlx                  | Diesel ou SeaORM       |
| PHP     | PDO raw               | Eloquent (Laravel)     |
| Ruby    | pg gem raw            | Sequel ou ActiveRecord |

---

## Frontends — 9 clientes

### Web (4)

| Pasta          | Stack                              | Status     |
|----------------|------------------------------------|------------|
| web-react/     | React 18 + TypeScript + TanStack Query + Tailwind | ⏳ |
| web-vue/       | Vue 3 + TypeScript + Pinia + Tailwind              | ⏳ |
| web-angular/   | Angular 17+ + TypeScript + RxJS + Angular Material | ⏳ |
| web-flutter/   | Flutter Web (compartilha código com mobile-flutter)| ⏳ |

### Desktop (3)

| Pasta              | Stack                                    | Status |
|--------------------|------------------------------------------|--------|
| desktop-flutter/   | Flutter Desktop (Windows/macOS/Linux)    | ⏳     |
| desktop-electron/  | Electron + React (JS nativo para desktop)| ⏳     |
| desktop-tauri/     | Tauri + React (Rust + WebView, leve)     | ⏳     |

### Mobile (2)

| Pasta          | Stack                                    | Status |
|----------------|------------------------------------------|--------|
| mobile-flutter/| Flutter iOS + Android (mesmo código web) | ⏳     |
| mobile-rn/     | React Native iOS + Android (TypeScript)  | ⏳     |

---

## Telas e Ações — Todos os Frontends

Todas as 9 interfaces implementam as mesmas telas e ações.

### Tela 1 — Login
**Ações:** entrar com email + senha → JWT salvo → redirecionar para Home
**API:** POST /auth/login
**Redis:** cria session:{userId} + lida com rate limiting de tentativas

### Tela 2 — Home / Dashboard
**Ações:** ver listagem de trens em cards, buscar por nome, filtrar por status/tração/bitola, ordenar, paginar
**API:** GET /train-models?q=&status=&traction=&sort=&page=&limit=
**Redis:** lê cache:trains:list (TTL 60s)
**Elementos UI:** grid de cards, barra de busca, dropdowns de filtro, paginação

### Tela 3 — Detalhe do Trem
**Ações:** ver todos os dados do trem, galeria de imagens, player de vídeo, player de áudio (som do motor), download de PDF spec sheet, ver histórico de edições (MongoDB)
**API:** GET /train-models/:id
**Redis:** lê cache:trains:{id} (TTL 300s)
**MongoDB:** GET /train-models/:id/history (train_edit_history)
**Elementos UI:** hero image, tabs (info / mídias / técnico / histórico), mapa com geodados da fábrica + rota histórica, audio player, video player

### Tela 4 — Criar Trem (ADMIN/OPERATOR)
**Ações:** preencher formulário completo, upload de imagem principal, upload de galeria (múltiplos arquivos), upload de vídeo, upload de áudio, upload de PDF, salvar
**API:** POST /train-models + POST /train-models/:id/media (por tipo)
**Elementos UI:** formulário multi-step ou tabs, drag-and-drop de arquivos, preview de mídia antes de salvar, mapa interativo para marcar localização da fábrica

### Tela 5 — Editar Trem (ADMIN/OPERATOR)
**Ações:** editar qualquer campo, trocar mídias, salvar (gera registro no MongoDB)
**API:** PUT /train-models/:id
**MongoDB:** insere em train_edit_history automaticamente após salvar
**Elementos UI:** igual ao Criar, mas pré-populado

### Tela 6 — Perfil do Usuário
**Ações:** ver dados do próprio perfil, editar display_name/bio/location/website, fazer upload de avatar, alterar senha, ver log de atividade recente (MongoDB)
**API:** GET /users/me, PUT /users/me, POST /users/me/avatar, PUT /users/me/password
**MongoDB:** GET /users/me/activity (user_activity_log)
**Elementos UI:** avatar com upload, formulário editável, lista de atividade recente

### Tela 7 — Admin: Gerenciar Usuários (ADMIN only)
**Ações:** listar usuários, ver perfil de qualquer usuário, alterar role, ativar/desativar conta, resetar senha
**API:** GET /users, GET /users/:id, PUT /users/:id/role, PUT /users/:id/status
**Elementos UI:** tabela com filtros, modal de confirmação para ações críticas

### Tela 8 — Logout
**Ações:** invalidar JWT (blacklist Redis), limpar session, redirecionar para Login
**API:** POST /auth/logout
**Redis:** SET blacklist:jwt:{jti} + DEL session:{userId}

---

## Endpoints REST — todos os backends implementam

```
Auth
  POST   /auth/login              → retorna JWT
  POST   /auth/logout             → invalida JWT no Redis
  POST   /auth/refresh            → renova JWT (Fase 2)

Users
  GET    /users                   → lista (ADMIN)
  GET    /users/:id               → detalhe
  GET    /users/me                → próprio perfil
  PUT    /users/me                → editar próprio perfil
  PUT    /users/me/password       → alterar senha
  POST   /users/me/avatar         → upload avatar
  GET    /users/me/activity       → activity log (MongoDB)
  PUT    /users/:id/role          → alterar role (ADMIN)
  PUT    /users/:id/status        → ativar/desativar (ADMIN)
  DELETE /users/:id               → deletar (ADMIN)

Train Models
  GET    /train-models            → listagem com filtros + paginação (cache Redis)
  GET    /train-models/:id        → detalhe (cache Redis)
  POST   /train-models            → criar (ADMIN/OPERATOR)
  PUT    /train-models/:id        → editar + gera MongoDB history (ADMIN/OPERATOR)
  DELETE /train-models/:id        → deletar (ADMIN)
  GET    /train-models/:id/history → histórico MongoDB

Upload de mídias (multipart/form-data)
  POST   /train-models/:id/image  → imagem principal
  POST   /train-models/:id/gallery → múltiplas imagens
  POST   /train-models/:id/video  → vídeo
  POST   /train-models/:id/audio  → áudio (som do motor)
  POST   /train-models/:id/spec   → PDF spec sheet
  GET    /train-models/:id/spec   → download PDF

System
  GET    /health                  → status da API + DB providers ativos
```

---

## O que NÃO está no escopo atual

Implementar nas fases posteriores, não agora:
- LGPD / PIPEDA / audit_logs / criptografia AES-256
- OAuth / SSO / autenticação social
- Testes automatizados (unit, integration, e2e)
- Deploy / CI/CD / Kubernetes
- WebSockets / realtime
- Notificações push
- Internacionalização (i18n)

---

## Convenções de código (todas as stacks)

- Idioma do código: inglês (variáveis, funções, classes, arquivos)
- Comentários: podem ser em português
- IDs: sempre UUID v4
- Datas: sempre com timezone (TIMESTAMPTZ no PG, ISODate no Mongo)
- Erros: sempre retornar `{ error: string, code?: string }` padronizado
- HTTP status codes: 200 OK, 201 Created, 204 No Content, 400 Bad Request,
  401 Unauthorized, 403 Forbidden, 404 Not Found, 409 Conflict, 429 Too Many Requests, 500 Internal Server Error

---

## Como usar este arquivo

O Cursor AI e o GitHub Copilot leem este arquivo como contexto.
Antes de pedir ajuda em qualquer subpasta, referencie com @architecture.md.
Atualize o campo Status das tabelas conforme cada implementação avança.