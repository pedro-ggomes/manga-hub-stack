-- migrate:up
CREATE EXTENSION citext;
CREATE EXTENSION pgcrypto;

-- Never exposed through PostgREST: credentials, and internal helpers.
CREATE SCHEMA auth;
CREATE SCHEMA private;

CREATE TABLE auth.account (
    id            uuid PRIMARY KEY DEFAULT uuidv7(),
    email         citext NOT NULL UNIQUE CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    password_hash text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TYPE manga_status AS ENUM ('reading', 'completed', 'on_hold', 'dropped', 'plan_to_read');

-- sites: [{url: http(s) string, type: primary|alt}], at most one primary.
CREATE FUNCTION private.is_valid_sites(sites jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN jsonb_typeof(sites) <> 'array' THEN false ELSE (
        -- coalesce per element: a missing key yields NULL, which bool_and would skip
        SELECT coalesce(bool_and(coalesce(
                   jsonb_typeof(e) = 'object'
                   AND e->>'type' IN ('primary', 'alt')
                   AND jsonb_typeof(e->'url') = 'string'
                   AND e->>'url' ~* '^https?://\S+$', false)), true)
               AND count(*) FILTER (WHERE e->>'type' = 'primary') <= 1
        FROM jsonb_array_elements(sites) AS e
    ) END
$$;

CREATE FUNCTION private.set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

CREATE TABLE manga (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title      citext NOT NULL UNIQUE CHECK (title <> '' AND title = btrim(title) AND length(title) <= 200),
    sites      jsonb NOT NULL DEFAULT '[]' CHECK (private.is_valid_sites(sites)),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER manga_set_updated_at BEFORE UPDATE ON manga
    FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();

CREATE TABLE user_progress (
    user_id           uuid NOT NULL REFERENCES auth.account (id) ON DELETE CASCADE,
    manga_id          bigint NOT NULL REFERENCES manga (id) ON DELETE CASCADE,
    status            manga_status NOT NULL DEFAULT 'plan_to_read',
    -- plain numeric + trunc check: numeric(7,1) would silently round 12.25 to 12.3
    last_chapter_read numeric NOT NULL DEFAULT 0
        CHECK (last_chapter_read >= 0 AND last_chapter_read < 100000 AND last_chapter_read = trunc(last_chapter_read, 1)),
    worth_reading     boolean,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, manga_id)
);
CREATE INDEX user_progress_manga_id_idx ON user_progress (manga_id);
CREATE TRIGGER user_progress_set_updated_at BEFORE UPDATE ON user_progress
    FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();

-- migrate:down
DROP TABLE user_progress;
DROP TABLE manga;
DROP FUNCTION private.set_updated_at();
DROP FUNCTION private.is_valid_sites(jsonb);
DROP TYPE manga_status;
DROP TABLE auth.account;
DROP SCHEMA private;
DROP SCHEMA auth;
DROP EXTENSION pgcrypto;
DROP EXTENSION citext;
