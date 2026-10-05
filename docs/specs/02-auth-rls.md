# 02 — Auth, RLS and the REST API ⛔ core

## Domain
People sign up with email + password, log in, and get a token. With it they can read
the whole catalog, add titles to it, edit titles they added, and fully manage their
own progress, and nobody else's. Without a token they can only sign up or log in.

**Done when:** the REST API (PostgREST) serves the schema, and every rule below holds
both in pgTAP (as the API roles) and over HTTP, including under concurrent requests.

## Technical
- **Roles** (cluster-wide, created idempotently, never dropped by `down` because the
  dev and test DBs share them): `authenticator` (LOGIN NOINHERIT, password set by
  `make configure` from `AUTHENTICATOR_PASSWORD`), `anon`, `authenticated`.
- **Tokens:** HS256 JWT built in SQL with pgcrypto `hmac`: `{sub, role: authenticated,
  iat, exp}`. Secret and TTL live in `auth.jwt_config` (single row, written by
  `make configure` from `JWT_SECRET`/`JWT_TTL`; never in a migration). PostgREST
  verifies with the same `JWT_SECRET`.
- **RPCs** (`SECURITY DEFINER`, `search_path = extensions, pg_temp`: pg_temp last so
  temp objects can't shadow anything), the only things `anon` can call:
  - `signup(email, password) → {token}`; password 12–72 bytes (bcrypt ignores bytes
    past 72), bcrypt cost 12. Duplicate email → 409 (signup necessarily reveals that
    an email is taken).
  - `login(email, password) → {token}`; wrong password and unknown email return the
    same 401, and unknown email still runs a bcrypt compare against a dummy hash so
    response time doesn't reveal which emails exist. Tested deterministically by
    counting `crypt` calls (`track_functions`), not by timing.
- **Extensions move to schema `extensions`** (new migration; slice 01 is frozen) so
  pgcrypto/citext functions aren't exposed as `/rpc/*`. The DB `search_path` becomes
  `public, extensions`; PostgREST gets `db-extra-search-path=extensions`.
- `EXECUTE` on functions is revoked from `PUBLIC` in `public` (now and by default).
- **Privileges + RLS:**
  | Table | `anon` | `authenticated` |
  |---|---|---|
  | `manga` | none | SELECT all; INSERT `(title, sites)`; UPDATE `(title, sites)` where `created_by` = me; no DELETE |
  | `user_progress` | none | SELECT/INSERT/UPDATE/DELETE where `user_id` = me; INSERT `(manga_id, status, last_chapter_read, worth_reading)`, UPDATE same minus `manga_id` |
  | `auth.*` | none | none |
  Column grants mean `user_id`, `created_by`, `id` and timestamps can't be set by
  clients at all (role-escalation guard); defaults fill them from the token.
- `manga.created_by uuid` (default = caller, `ON DELETE SET NULL`); the seed sets it
  to the demo account so seeded titles are editable by the demo user.
- `make configure` (idempotent, reads env via psql `\getenv`): authenticator password
  and `auth.jwt_config`. `make bootstrap` = up → migrate → configure → seed.
- **API tests** (`tests/api/*.test.ts`, `node --test`, no deps) run against a second
  PostgREST (`postgrest-test`, port 3001) pointed at the throwaway `manga_test` DB, so
  they never write to dev data.

### Options considered
- *JWT secret as a DB setting (`app.jwt_secret`), as in the PostgREST tutorial*:
  any role can read settings with `current_setting()`. A table only the owner can
  read is tighter.
- *pgjwt extension*: unmaintained; HS256 is ~10 lines of SQL with pgcrypto.
- *Any authenticated user may edit any catalog row (wiki-style)*: simpler, but one
  user could rewrite everyone's links. Creator-only for now.
- *argon2 (global CLAUDE.md preference)*: not available in SQL; bcrypt is. Deviation
  recorded here.
- *Rate limiting on login*: PostgREST has none. Out of scope for local use; needed
  before exposing the API (reverse proxy). Open issue.

## Acceptance criteria (EARS)
`db/tests/03_auth.sql`, `db/tests/04_rls.sql`, `tests/api/*.test.ts`
1. WHEN someone signs up with a valid email and a 12–72 byte password, THE SYSTEM
   SHALL create the account with a bcrypt hash and return a token whose signature
   verifies with `JWT_SECRET` and whose claims are `sub` = account id,
   `role` = `authenticated`, `exp` = now + TTL.
2. WHEN the password is shorter than 12 or longer than 72 bytes, or the email is
   malformed, THE SYSTEM SHALL reject the signup (HTTP 400).
3. WHEN the email is already registered (any case), THE SYSTEM SHALL reject the
   signup (HTTP 409); WHEN 10 signups for one email arrive concurrently, exactly one
   SHALL succeed.
4. WHEN credentials are correct, login SHALL return a valid token; WHEN the password
   is wrong or the email unknown, THE SYSTEM SHALL return the same 401 error.
5. WHEN a request has no token, THE SYSTEM SHALL allow only `signup` and `login`
   (no table, no other function, nothing in `auth`).
6. WHEN an authenticated user reads, THE SYSTEM SHALL return every catalog row and
   only that user's progress rows.
7. WHEN a user inserts a manga, THE SYSTEM SHALL record them as `created_by`; WHEN 20
   inserts of one title arrive concurrently, exactly one SHALL succeed (others 409).
8. WHEN a user updates a manga they didn't create, THE SYSTEM SHALL change nothing;
   WHEN anyone deletes a manga through the API, THE SYSTEM SHALL refuse.
9. WHEN a user inserts, updates or deletes progress, THE SYSTEM SHALL only ever touch
   rows with their own `user_id`, and SHALL refuse a client-supplied `user_id`,
   `created_by` or `id`.
10. WHEN a token is expired or signed with another secret, THE SYSTEM SHALL return 401.
