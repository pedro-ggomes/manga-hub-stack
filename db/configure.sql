-- Environment-specific settings that must never live in a migration. Idempotent.
-- Run with `make configure`; values come from env vars via \getenv, never argv.
\getenv authenticator_password AUTHENTICATOR_PASSWORD
\getenv jwt_secret JWT_SECRET
\getenv jwt_ttl JWT_TTL
SELECT set_config('cfg.authenticator_password', :'authenticator_password', true) IS NOT NULL AS cfg_a,
       set_config('cfg.jwt_secret', :'jwt_secret', true) IS NOT NULL AS cfg_b,
       set_config('cfg.jwt_ttl', :'jwt_ttl', true) IS NOT NULL AS cfg_c \gset

DO $$
BEGIN
    IF length(current_setting('cfg.authenticator_password')) < 16 THEN
        RAISE EXCEPTION 'AUTHENTICATOR_PASSWORD must be at least 16 characters';
    END IF;
    IF length(current_setting('cfg.jwt_secret')) < 32 THEN
        RAISE EXCEPTION 'JWT_SECRET must be at least 32 characters';
    END IF;
    EXECUTE format('ALTER ROLE authenticator PASSWORD %L', current_setting('cfg.authenticator_password'));
END
$$;

INSERT INTO auth.jwt_config (secret, ttl)
VALUES (current_setting('cfg.jwt_secret'), current_setting('cfg.jwt_ttl')::interval)
ON CONFLICT (singleton) DO UPDATE SET secret = excluded.secret, ttl = excluded.ttl;
