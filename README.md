# manga-hub-stack

A Postgres-centric manga tracking hub. Most of the backend lives in the database itself:
PostgREST exposes the schema as a REST API, row-level security handles authorization,
and extensions cover search, recommendations, and scheduled jobs. A small Vite frontend
sits on top, with Electric SQL for local-first sync.

> **Status:** scaffolding only. The file structure is in place and the files are empty.
> This README will be filled in as each phase lands.

## Stack

| Layer          | Tech                                                    |
| -------------- | ------------------------------------------------------- |
| Database       | PostgreSQL + `pgcrypto`, `pgvector`, `pg_cron`, `pg_graphql` |
| API            | PostgREST (auto-generated REST from the schema)         |
| Sync           | Electric SQL (local-first)                              |
| Analytics      | pg_mooncake (columnar)                                  |
| Embeddings     | pgai                                                    |
| Frontend       | Vite (framework TBD: React, Svelte, or Vue)             |
| Runtime        | Docker Compose                                          |

## Roadmap

- [ ] **Phase 1: Core schema.** Extensions, `mangas` table, `manga_status` enum, seed of 18 titles
- [ ] **Phase 2: Auth.** Password hashing and JWT generation in SQL, RLS policies
- [ ] **Phase 3: Recommendations.** Synopsis embeddings and pgvector cosine similarity search
- [ ] **Phase 4: Automation & analytics.** pg_cron jobs, pg_mooncake columnar analytics
- [ ] **Phase 5: Local-first.** Electric SQL sync in the frontend

## Layout

```
docker/          Container builds and service config (Postgres, PostgREST)
db/init/         SQL run automatically on first container boot
db/functions/    Stored procedures and triggers (auth, vector search, cron)
db/policies/     Row-level security definitions
db/migrations/   Versioned schema changes
config/          Electric SQL and pg_mooncake config
scripts/         DB reset and embedding generation helpers
frontend/        Web app (PostgREST client, Electric client, UI components)
```

## Getting started

_Coming soon._ Planned flow:

```bash
cp .env.example .env      # fill in DB credentials and JWT secret
docker compose up -d
```
