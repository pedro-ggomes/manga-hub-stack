BEGIN;
SELECT plan(7);

SELECT ok(
    EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = ext),
    format('extension %s is available', ext)
)
FROM unnest(ARRAY['vector', 'pg_cron', 'pg_graphql', 'pgcrypto', 'citext', 'pgtap']) AS ext;

SELECT ok(
    'pg_cron' = ANY (string_to_array(current_setting('shared_preload_libraries'), ',')),
    'pg_cron is preloaded'
);

SELECT * FROM finish();
ROLLBACK;
