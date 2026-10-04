# 01 — Schema + seed ⛔ core

## Domain
Several people track the manga they read. The catalog (title, where to read it) is
shared; each person's progress (status, last chapter, whether it's worth reading) is
their own. The seed loads the current reading list as a demo user's progress.

**Done when:** the schema enforces every rule below in the database, and the seed
loads the 18 titles with the demo user's progress intact.

## Technical
- `auth.account(id uuid uuidv7, email citext unique, password_hash, created_at)`.
  Created here only because `user_progress` references it; signup/login, roles and
  RLS are slice 02. The `auth` schema is never exposed by PostgREST.
- `manga_status` enum: `reading, completed, on_hold, dropped, plan_to_read`.
- `manga(id identity, title, sites jsonb, created_at, updated_at)`.
  - `title citext UNIQUE`: non-blank, trimmed (no leading/trailing spaces), ≤ 200
    chars; equality and uniqueness are case-insensitive everywhere (PostgREST `eq` too).
  - `sites`: JSON array of `{url, type}`; `url` is an http(s) string; `type` is
    `primary` or `alt`; at most one `primary`. Empty array allowed (plan-to-read
    titles may have no source yet). Validated by `private.is_valid_sites(jsonb)` in a
    CHECK. Helpers live in schema `private`, which PostgREST never exposes.
- `user_progress(user_id, manga_id, status, last_chapter_read, worth_reading, created_at, updated_at)`.
  - PK `(user_id, manga_id)`: one row per person per manga.
  - `last_chapter_read numeric`, 0 ≤ x < 100000, at most one decimal (Kingdom 703.7).
    Plain `numeric` + `x = trunc(x, 1)` because `numeric(7,1)` silently rounds 12.25.
  - `worth_reading boolean NULL`: null = no opinion yet.
  - Cascades: deleting an account or a manga deletes its progress rows.
- `updated_at` maintained by a shared `set_updated_at()` BEFORE UPDATE trigger.
- Seed (`db/seed.sql`, dev only, idempotent): demo account `demo@manga.local`, the 18
  titles, and progress rows. The password is read from the `DEMO_PASSWORD` env var via
  psql `\getenv` (never on a command line), must be ≥ 12 chars, and re-seeding applies
  a changed password.
- Columns used by later slices (`synopsis`, `embedding`, `created_by`) are added there.

### Options considered
- *`manga_site` table instead of `sites jsonb`*: declarative constraints, but every
  add-manga becomes two inserts or an RPC. Kept jsonb (your seed's shape, one insert)
  with one validation function; revisit if sites need their own queries.
- *Keep `metadata jsonb`*: its only key became the typed `worth_reading` column.
- *Status on `manga`*: your seed's shape, but status is per person in a multi-user app.

## Acceptance criteria (EARS) → `db/tests/01_schema.sql`, `db/tests/02_seed.sql`
1. THE SYSTEM SHALL define `manga_status` with exactly the five statuses, in order.
2. WHEN a manga is inserted with a title equal to an existing one ignoring case,
   THE SYSTEM SHALL reject it (unique violation); title lookups SHALL ignore case.
3. WHEN a manga title is blank, has leading/trailing whitespace, or is longer than
   200 chars, THE SYSTEM SHALL reject it.
4. WHEN `sites` is not an array, has an element without an http(s) `url`, has a
   `type` other than `primary`/`alt`, or has two `primary` entries, THE SYSTEM SHALL
   reject it; an empty array, one primary + alts, and uppercase schemes SHALL be accepted.
   The validator SHALL NOT live in the API-exposed `public` schema.
5. WHEN `last_chapter_read` is negative, ≥ 100000, or has more than one decimal place,
   THE SYSTEM SHALL reject it; 703.7 SHALL round-trip exactly.
6. WHEN a second progress row for the same user and manga is inserted, THE SYSTEM
   SHALL reject it.
7. WHEN progress is inserted without status or chapter, THE SYSTEM SHALL default to
   `plan_to_read` and 0.
8. WHEN a manga or progress row is updated, THE SYSTEM SHALL set `updated_at` to the
   transaction time.
9. WHEN an account or a manga is deleted, THE SYSTEM SHALL delete its progress rows.
10. WHEN an account email is malformed or duplicates another ignoring case, THE
    SYSTEM SHALL reject it.
11. WHEN the seed is loaded twice, THE SYSTEM SHALL contain 18 titles and 18 demo
    progress rows, with Kingdom at 703.7 and Steel Ball Run `plan_to_read` with
    `worth_reading` null, and the demo password SHALL be the second one.
12. WHEN `DEMO_PASSWORD` is unset or shorter than 12 chars, `make seed` SHALL fail
    without writing anything. → verified by hand (psql meta-commands can't run inside
    a pgTAP assertion): see PR.
