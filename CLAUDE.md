# CLAUDE.md — manga-hub-stack

Project overrides for the global CLAUDE.md. Where this file is silent, the global one applies.

## Stack
Postgres 18 is the backend: PostgREST serves the schema, RLS authorizes, logic lives
in SQL functions. Extensions: pgvector, pg_cron, pg_graphql, pgcrypto, citext,
pg_mooncake (slice 8). Migrations: dbmate. DB tests: pgTAP. Frontend: Vite + React + TS,
Vitest. The only hand-written server (Electric auth proxy) is Python/FastAPI.
Plan and slice order: `docs/PLAN.md`. Specs: `docs/specs/`.

## Commands
`make help` lists everything. The gate is `make test`; it must be green before any
slice is reported done.

## Core (human gate before merge)
- `auth` schema, signup/login/JWT functions, role grants
- RLS policies
- Migrations that change or drop existing columns/data
- Anything replication-related (Electric, pg_mooncake)

## Never
1. Never edit a migration that has been merged to `main` (after its human gate). Add a
   new migration instead. Unmerged migrations may be edited: `make migrate-redo` if only
   the `up` section changed, `make reset` if `down` changed too (the new `down` cannot
   roll back the old `up`).
   Enforced by `make check-frozen` in CI.
2. Never commit `.env` or any secret. Config comes from the environment.
3. Never grant table privileges to `anon`, and never expose the `auth` schema through
   PostgREST.

## Conventions
- Singular snake_case table names, `_id` FKs, `_at` timestamps.
- Every migration has a working `-- migrate:down` (`make check-migrations`).
- Extensions are created in the slice that first uses them.
- Each slice: spec (EARS) → failing test → minimum code → `make test` →
  `/code-review` + `/ponytail-review` → PR.
