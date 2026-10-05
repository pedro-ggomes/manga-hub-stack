-- migrate:up

-- Extensions out of `public`, so PostgREST never exposes their functions as /rpc/*.
CREATE SCHEMA extensions;
ALTER EXTENSION pgcrypto SET SCHEMA extensions;
ALTER EXTENSION citext SET SCHEMA extensions;
DO $$ BEGIN
    EXECUTE format('ALTER DATABASE %I SET search_path = public, extensions', current_database());
END $$;
SET search_path = public, extensions;

-- Functions are no longer executable by everyone by default; the API gets explicit grants.
-- Global revoke because per-schema default privileges can only add, never remove.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
-- ...except helpers that constraints/policies call, and extension functions (operators).
ALTER DEFAULT PRIVILEGES IN SCHEMA private GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA extensions GRANT EXECUTE ON FUNCTIONS TO PUBLIC;

-- Roles are cluster-wide and shared by the dev and test DBs, so they're created
-- idempotently and never dropped by `down`. The authenticator password is set by
-- `make configure`, never here.
DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN CREATE ROLE authenticator LOGIN NOINHERIT; END IF;
END $$;
GRANT anon, authenticated TO authenticator;

-- Who is calling: the `sub` claim PostgREST puts in request.jwt.claims.
CREATE FUNCTION private.current_user_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
    SELECT (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;

ALTER TABLE manga
    ADD COLUMN created_by uuid DEFAULT private.current_user_id() REFERENCES auth.account (id) ON DELETE SET NULL;
ALTER TABLE user_progress ALTER COLUMN user_id SET DEFAULT private.current_user_id();

-- Policies wrap current_user_id() in a sub-SELECT so it runs once per query, not per row.

-- Privileges. Column lists keep id, user_id, created_by and timestamps out of clients' hands.
GRANT USAGE ON SCHEMA public, extensions TO anon, authenticated;
GRANT SELECT ON manga TO authenticated;
GRANT INSERT (title, sites), UPDATE (title, sites) ON manga TO authenticated;
GRANT SELECT, DELETE ON user_progress TO authenticated;
GRANT INSERT (manga_id, status, last_chapter_read, worth_reading),
      UPDATE (status, last_chapter_read, worth_reading) ON user_progress TO authenticated;

ALTER TABLE manga ENABLE ROW LEVEL SECURITY;
CREATE POLICY manga_read ON manga FOR SELECT TO authenticated USING (true);
CREATE POLICY manga_insert ON manga FOR INSERT TO authenticated
    WITH CHECK (created_by = (SELECT private.current_user_id()));
CREATE POLICY manga_update_own ON manga FOR UPDATE TO authenticated
    USING (created_by = (SELECT private.current_user_id()));

ALTER TABLE user_progress ENABLE ROW LEVEL SECURITY;
CREATE POLICY user_progress_own ON user_progress FOR ALL TO authenticated
    USING (user_id = (SELECT private.current_user_id()))
    WITH CHECK (user_id = (SELECT private.current_user_id()));

-- JWT signing config: one row, written by `make configure`. Only the owner can read it.
CREATE TABLE auth.jwt_config (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    secret    text NOT NULL CHECK (length(secret) >= 32),
    ttl       interval NOT NULL CHECK (ttl > interval '0')
);

CREATE FUNCTION private.base64url(data bytea) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT rtrim(translate(encode(data, 'base64'), E'+/\n', '-_'), '=')
$$;

-- HS256 JWT, verified by PostgREST with the same JWT_SECRET.
CREATE FUNCTION auth.token_for(account_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = extensions AS $$
DECLARE
    cfg auth.jwt_config;
    signing_input text;
BEGIN
    SELECT * INTO cfg FROM auth.jwt_config;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JWT is not configured; run make configure';
    END IF;
    signing_input := private.base64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8')) || '.'
        || private.base64url(convert_to(jsonb_build_object(
               'sub', account_id,
               'role', 'authenticated',
               -- floor: a rounded-up iat lands in the future and PostgREST rejects it
               'iat', floor(extract(epoch FROM now()))::bigint,
               'exp', floor(extract(epoch FROM now() + cfg.ttl))::bigint)::text, 'utf8'));
    RETURN jsonb_build_object('token',
        signing_input || '.' || private.base64url(hmac(signing_input, cfg.secret, 'sha256')));
END
$$;

CREATE FUNCTION public.signup(email text, password text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = extensions, pg_temp AS $$
DECLARE
    new_id uuid;
BEGIN
    IF email IS NULL OR password IS NULL THEN
        RAISE EXCEPTION 'email and password are required' USING ERRCODE = '22023';
    END IF;
    -- bcrypt silently ignores bytes past 72
    IF length(password) < 12 OR octet_length(password) > 72 THEN
        RAISE EXCEPTION 'password must be at least 12 characters and at most 72 bytes' USING ERRCODE = '22023';
    END IF;
    INSERT INTO auth.account (email, password_hash)
    VALUES (signup.email, crypt(password, gen_salt('bf', 12)))
    RETURNING id INTO new_id;
    RETURN auth.token_for(new_id);
END
$$;

CREATE FUNCTION public.login(email text, password text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = extensions, pg_temp AS $$
DECLARE
    acct auth.account;
    attempt text;
BEGIN
    SELECT * INTO acct FROM auth.account a WHERE a.email = login.email::citext;
    -- Always run the bcrypt compare (against a dummy hash for unknown emails) BEFORE
    -- branching, so response time doesn't reveal which emails exist.
    attempt := crypt(coalesce(password, ''), coalesce(acct.password_hash,
        '$2a$12$fbWcy8L44d6HWdNN5V//9uaDuRP/ybPUPP1R6b818a9V/bGlhPdfi'));
    IF acct.id IS NULL OR attempt <> acct.password_hash THEN
        RAISE SQLSTATE 'PT401' USING MESSAGE = 'invalid email or password';
    END IF;
    RETURN auth.token_for(acct.id);
END
$$;

GRANT EXECUTE ON FUNCTION public.signup(text, text), public.login(text, text) TO anon, authenticated;

-- migrate:down
REVOKE EXECUTE ON FUNCTION public.signup(text, text), public.login(text, text) FROM anon, authenticated;
DROP FUNCTION public.login(text, text);
DROP FUNCTION public.signup(text, text);
DROP FUNCTION auth.token_for(uuid);
DROP FUNCTION private.base64url(bytea);
DROP TABLE auth.jwt_config;

DROP POLICY user_progress_own ON user_progress;
ALTER TABLE user_progress DISABLE ROW LEVEL SECURITY;
DROP POLICY manga_update_own ON manga;
DROP POLICY manga_insert ON manga;
DROP POLICY manga_read ON manga;
ALTER TABLE manga DISABLE ROW LEVEL SECURITY;

REVOKE ALL ON user_progress, manga FROM anon, authenticated;
REVOKE USAGE ON SCHEMA public, extensions FROM anon, authenticated;

ALTER TABLE user_progress ALTER COLUMN user_id DROP DEFAULT;
ALTER TABLE manga DROP COLUMN created_by;
DROP FUNCTION private.current_user_id();

ALTER DEFAULT PRIVILEGES IN SCHEMA extensions REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA private REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO PUBLIC;

DO $$ BEGIN
    EXECUTE format('ALTER DATABASE %I RESET search_path', current_database());
END $$;
ALTER EXTENSION citext SET SCHEMA public;
ALTER EXTENSION pgcrypto SET SCHEMA public;
DROP SCHEMA extensions;
