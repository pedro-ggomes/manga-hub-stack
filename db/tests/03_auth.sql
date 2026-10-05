BEGIN;
SELECT plan(29);
-- Must be on before login() is first called: instrumentation is fixed when its plan is cached.
SET LOCAL track_functions = 'all';

INSERT INTO auth.jwt_config (secret, ttl) VALUES ('test-secret-test-secret-test-secret', '1 hour')
ON CONFLICT (singleton) DO UPDATE SET secret = excluded.secret, ttl = excluded.ttl;

-- verify a token the way PostgREST does: recompute the HS256 signature
CREATE FUNCTION pg_temp.jwt_ok(token text, secret text) RETURNS boolean LANGUAGE sql AS $$
    SELECT split_part(token, '.', 3) = rtrim(translate(encode(
        extensions.hmac(split_part(token, '.', 1) || '.' || split_part(token, '.', 2), secret, 'sha256'),
        'base64'), E'+/\n', '-_'), '=')
$$;
CREATE FUNCTION pg_temp.part(token text, n int) RETURNS jsonb LANGUAGE sql AS $$
    SELECT convert_from(decode(rpad(translate(p, '-_', '+/'), (length(p) + 3) / 4 * 4, '='), 'base64'), 'utf8')::jsonb
    FROM split_part(token, '.', n) AS p
$$;
CREATE FUNCTION pg_temp.claims(token text) RETURNS jsonb LANGUAGE sql AS $$ SELECT pg_temp.part(token, 2) $$;

-- 1 signup
SELECT signup('reader@test.local', 'correct-horse-battery') ->> 'token' AS t \gset
SELECT ok(pg_temp.jwt_ok(:'t', 'test-secret-test-secret-test-secret'), 'signup token signature verifies');
SELECT ok(NOT pg_temp.jwt_ok(:'t', 'another-secret-another-secret-xx'), 'signature does not verify with another secret');
SELECT is(pg_temp.claims(:'t') ->> 'role', 'authenticated', 'token role is authenticated');
SELECT is((pg_temp.claims(:'t') ->> 'sub')::uuid, (SELECT id FROM auth.account WHERE email = 'reader@test.local'), 'token sub is the account id');
SELECT is((pg_temp.claims(:'t') ->> 'exp')::bigint - (pg_temp.claims(:'t') ->> 'iat')::bigint, 3600::bigint, 'token lives for the configured TTL');
SELECT is((pg_temp.claims(:'t') ->> 'iat')::bigint, floor(extract(epoch FROM now()))::bigint, 'token iat is now, never in the future');
SELECT ok((SELECT password_hash = extensions.crypt('correct-horse-battery', password_hash) AND password_hash LIKE '$2a$12$%'
           FROM auth.account WHERE email = 'reader@test.local'), 'password stored as bcrypt cost 12');
SELECT is(pg_temp.part(:'t', 1), '{"alg": "HS256", "typ": "JWT"}'::jsonb, 'header is HS256');

-- 2 validation
SELECT throws_ok($$SELECT signup('short@test.local', 'elevenchars')$$, '22023', NULL, '11-char password is rejected');
SELECT lives_ok($$SELECT signup('twelve@test.local', 'twelve-chars')$$, '12-char password is accepted');
SELECT throws_ok(format('SELECT signup(%L, %L)', 'long@test.local', repeat('x', 73)), '22023', NULL, '73-byte password is rejected');
SELECT lives_ok(format('SELECT signup(%L, %L)', 'long72@test.local', repeat('x', 72)), '72-byte password is accepted');
SELECT throws_ok(format('SELECT signup(%L, %L)', 'multibyte@test.local', repeat('é', 37)), '22023', NULL, '74-byte multibyte password is rejected');
SELECT throws_ok($$SELECT signup('not-an-email', 'correct-horse-battery')$$, '23514', NULL, 'malformed email is rejected');
SELECT throws_ok($$SELECT signup(NULL, 'correct-horse-battery')$$, '22023', NULL, 'null email is rejected');

-- 3 duplicate
SELECT throws_ok($$SELECT signup('READER@test.local', 'correct-horse-battery')$$, '23505', NULL, 'duplicate email (any case) is rejected');

-- 4 login
SELECT ok(pg_temp.jwt_ok(login('Reader@Test.Local', 'correct-horse-battery') ->> 'token', 'test-secret-test-secret-test-secret'), 'login with correct password returns a valid token');
SELECT throws_ok($$SELECT login('reader@test.local', 'wrong-password-123')$$, 'PT401', 'invalid email or password', 'wrong password is rejected');
SELECT throws_ok($$SELECT login('nobody@test.local', 'wrong-password-123')$$, 'PT401', 'invalid email or password', 'unknown email gets the same error');
SELECT throws_ok($$SELECT login(NULL, NULL)$$, 'PT401', 'invalid email or password', 'null credentials get the same error');

-- 4 timing: unknown emails must still pay for a bcrypt compare (counted, not timed)
CREATE FUNCTION pg_temp.crypt_calls() RETURNS bigint LANGUAGE sql AS $$
    SELECT coalesce(sum(calls), 0) FROM pg_stat_xact_user_functions WHERE schemaname = 'extensions' AND funcname = 'crypt'
$$;
SELECT pg_temp.crypt_calls() AS before \gset
SELECT throws_ok($$SELECT login('nobody-timing@test.local', 'wrong-password-123')$$, 'PT401');
SELECT is(pg_temp.crypt_calls() - :before, 1::bigint, 'unknown email still runs one bcrypt compare');

-- hardening: definer functions resolve pg_temp last
SELECT is((SELECT array_agg(p.proname::text ORDER BY p.proname) FROM pg_proc p
           WHERE p.proname IN ('signup', 'login') AND p.prosecdef
             AND 'search_path=extensions, pg_temp' = ANY (p.proconfig)),
          ARRAY['login', 'signup'], 'signup/login are SECURITY DEFINER with search_path = extensions, pg_temp');

-- 5 what anon can reach
SELECT function_privs_are('public', 'signup', ARRAY['text', 'text'], 'anon', ARRAY['EXECUTE'], 'anon can call signup');
SELECT function_privs_are('public', 'login', ARRAY['text', 'text'], 'anon', ARRAY['EXECUTE'], 'anon can call login');
SELECT is(
    (SELECT array_agg(p.proname::text ORDER BY p.proname) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND has_function_privilege('anon', p.oid, 'EXECUTE')),
    ARRAY['login', 'signup'], 'anon can execute nothing else in public');
SELECT ok(NOT has_schema_privilege('anon', 'auth', 'USAGE') AND NOT has_schema_privilege('authenticated', 'auth', 'USAGE'),
          'API roles have no access to the auth schema');
SELECT ok(NOT has_table_privilege('anon', 'manga', 'SELECT') AND NOT has_table_privilege('anon', 'user_progress', 'SELECT'),
          'anon cannot read tables');
SELECT hasnt_function('public', 'crypt', 'pgcrypto is not exposed in public');

SELECT * FROM finish();
ROLLBACK;
