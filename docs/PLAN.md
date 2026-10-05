# Implementation plan

Approved 2026-10-04. One slice = one branch = one PR, each with a spec in
`docs/specs/` written before code. ⛔ = core: needs a human review gate before merge.

| # | Slice | Core | Spec | Status |
|---|-------|------|------|--------|
| 0 | Foundation: Postgres image, compose, Makefile, CI, migration checks, AI-workflow doc | | [00](specs/00-foundation.md) | merged #1 |
| 1 | Schema + seed: `manga`, `user_progress`, `manga_status`, constraints, triggers | ⛔ | [01](specs/01-schema.md) | merged #3 |
| 2 | Auth + RLS: signup/login RPCs, JWT in SQL, roles, policies, PostgREST | ⛔ | [02](specs/02-auth-rls.md) | PR #4 |
| 3 | Frontend read: login, library list, status filter, search, site links | | [03](specs/03-frontend-read.md) | PR #5 |
| 4 | Frontend write: add manga, track/untrack, chapter +1/set, status, worth-reading | | [04](specs/04-frontend-write.md) | PR #6 |
| 5 | pg_graphql via PostgREST `rpc/graphql`, RLS-respecting | | | |
| 6 | Recommendations: Jikan synopses, Ollama embeddings, pgvector HNSW, `recommend()` | | | |
| 7 | pg_cron: nightly progress snapshot, `reading_stats()` | | | |
| 8 | pg_mooncake columnstore analytics (preview build, revertible) | ⛔ | | |
| 9 | Electric live sync + FastAPI auth proxy | ⛔ | | |

## Decisions

- **Multi-user.** Shared `manga` catalog; per-user state in `user_progress`.
  The original seed's `status`, `last_chapter_read` and `metadata.worth_reading`
  move there. `metadata jsonb` was dropped: its only key became a typed column.
- **Postgres is the backend.** PostgREST serves the schema; RLS authorizes; logic
  is SQL functions. The only hand-written server is the Electric auth proxy (Python).
- **dbmate** for migrations: plain SQL, `up`/`down` in one file, `db/schema.sql`
  dump committed so PR diffs show the real schema change.
- **pgai replaced** by `scripts/generate-embeddings.py` + local Ollama: the
  timescale/pgai repo was archived in May 2026.
- **pg_mooncake** only ships a `18-v0.2-preview` image (Oct 2025) after the
  Databricks acquisition; it is isolated in slice 8 so it can be reverted alone.
- **pg_cron** lives in the `postgres` database (`cron.database_name`) and schedules
  into the app DB with `cron.schedule_in_database`, so test databases don't need it.
- **Extensions are created in the slice that first uses them**, not up front.

## Versions verified 2026-10-04 (npm / Docker Hub / GitHub)

postgres 18.6-trixie · PostgREST v16.4 · pgvector 0.8.6 (PGDG apt) · pg_cron 1.6.8 ·
pg_graphql 1.6.2 · dbmate 2.36.0 · Electric 1.8.1 · @electric-sql/client 1.5.28 ·
Vite 8.3 · React 19.3 · Vitest 5.0 · TypeScript 7.0
