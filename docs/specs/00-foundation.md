# 00 — Foundation

## Domain
Nothing in this repo runs yet. Before any feature, we need a reproducible local
database with every extension the roadmap needs, a single command surface
(`make`), a test gate that runs the same locally and in CI, and guard rails on
migrations.

**Done when:** a fresh clone can `cp .env.example .env && make up && make test`
and get green, and CI runs the same gate on every PR.

## Technical
- Image `docker/postgres/Dockerfile`: `postgres:18.6-trixie` + PGDG packages
  `postgresql-18-pgvector`, `postgresql-18-cron`, `postgresql-18-pgtap`, `pg_prove`;
  `pg_graphql` from its GitHub `.deb` (pinned by version arg). `pgcrypto` and
  `citext` ship with Postgres contrib.
- `pg_cron` needs `shared_preload_libraries`; set via the compose `command`, no
  custom `postgresql.conf`.
- Migrations: dbmate in a `tools`-profile container, files in `db/migrations`,
  schema dump in `db/schema.sql`.
- Tests: pgTAP files in `db/tests`, run by `pg_prove` inside the db container
  against a throwaway `manga_test` DB rebuilt from migrations every run.
- Config only via `.env` (git-ignored); `.env.example` holds safe dev defaults.

### Options considered
- *Prebuilt multi-extension images* (community images bundling pgvector+pg_cron):
  rejected, unknown maintainers for the most trusted container in the stack.
- *`db/init/*.sql` on first boot*: rejected, runs once per volume and drifts from
  migrations. Migrations are the only schema source.
- *Postgres `initdb` scripts for test DB*: rejected, `make test-db` recreates it
  each run so tests never depend on leftover state.

## Acceptance criteria (EARS)
1. WHEN the db container is up, THE SYSTEM SHALL offer the extensions `vector`,
   `pg_cron`, `pg_graphql`, `pgcrypto`, `citext` and `pgtap` for installation.
   → `db/tests/00_extensions.sql`
2. WHEN the db container is up, THE SYSTEM SHALL preload `pg_cron`.
   → `db/tests/00_extensions.sql`
3. WHEN `make test` runs, THE SYSTEM SHALL rebuild `manga_test` from migrations and
   run every `db/tests/*.sql` file, exiting non-zero on any failure.
4. WHEN `make check-migrations` runs, THE SYSTEM SHALL apply every migration, roll
   all of them back, and apply them again, failing if any step fails.
5. WHEN a branch modifies, renames or deletes a migration file that exists on
   `main`, THE SYSTEM SHALL fail `make check-frozen`.
   → verified by hand in the PR (see below), and enforced in CI.
6. WHEN a PR is opened, CI SHALL run criteria 1–5.
