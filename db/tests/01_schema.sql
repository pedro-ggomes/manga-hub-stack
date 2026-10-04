BEGIN;
SELECT plan(36);

-- fixtures
INSERT INTO auth.account (id, email, password_hash) VALUES
    ('00000000-0000-7000-8000-000000000001', 'a@test.local', 'x'),
    ('00000000-0000-7000-8000-000000000002', 'b@test.local', 'x');
INSERT INTO manga (title, sites) VALUES ('Test Manga', '[{"url": "https://a.example", "type": "primary"}]');
PREPARE new_manga(text, jsonb) AS INSERT INTO manga (title, sites) VALUES ($1, $2);

-- helpers live outside the API-exposed schema
SELECT hasnt_function('public', 'is_valid_sites', 'is_valid_sites is not in public (not callable via /rpc)');

-- 1 statuses
SELECT enum_has_labels('manga_status', ARRAY['reading', 'completed', 'on_hold', 'dropped', 'plan_to_read']);

-- 2 case-insensitive unique title
SELECT throws_ok($$EXECUTE new_manga('test MANGA', '[]')$$, '23505', NULL, 'duplicate title ignoring case is rejected');

-- 3 title shape
SELECT throws_ok($$EXECUTE new_manga('   ', '[]')$$, '23514', NULL, 'blank title is rejected');
SELECT throws_ok(format('EXECUTE new_manga(%L, %L)', repeat('x', 201), '[]'), '23514', NULL, '201-char title is rejected');
SELECT lives_ok(format('EXECUTE new_manga(%L, %L)', repeat('y', 200), '[]'), '200-char title is accepted');

SELECT throws_ok($$EXECUTE new_manga(' Test Manga', '[]')$$, '23514', NULL, 'leading whitespace in title is rejected');
SELECT throws_ok($$EXECUTE new_manga('Test Manga ', '[]')$$, '23514', NULL, 'trailing whitespace in title is rejected');
SELECT is((SELECT count(*) FROM manga WHERE title = 'TEST manga'), 1::bigint, 'title equality is case-insensitive');

-- 4 sites
SELECT lives_ok($$EXECUTE new_manga('Empty Sites', '[]')$$, 'empty sites array is accepted');
SELECT lives_ok($$EXECUTE new_manga('Primary And Alts', '[{"url": "https://a.example", "type": "primary"}, {"url": "http://b.example/x", "type": "alt"}, {"url": "https://c.example", "type": "alt"}]')$$, 'one primary plus alts is accepted');
SELECT lives_ok($$EXECUTE new_manga('Upper Scheme', '[{"url": "HTTPS://Example.com/x", "type": "primary"}]')$$, 'uppercase scheme is accepted');
SELECT throws_ok($$EXECUTE new_manga('S1', '{"url": "https://a.example", "type": "primary"}')$$, '23514', NULL, 'sites object (not array) is rejected');
SELECT throws_ok($$EXECUTE new_manga('S2', '[{"type": "primary"}]')$$, '23514', NULL, 'site without url is rejected');
SELECT throws_ok($$EXECUTE new_manga('S3', '[{"url": "ftp://a.example", "type": "primary"}]')$$, '23514', NULL, 'non-http url is rejected');
SELECT throws_ok($$EXECUTE new_manga('S4', '[{"url": 42, "type": "primary"}]')$$, '23514', NULL, 'non-string url is rejected');
SELECT throws_ok($$EXECUTE new_manga('S5', '[{"url": "https://a.example", "type": "mirror"}]')$$, '23514', NULL, 'unknown site type is rejected');
SELECT throws_ok($$EXECUTE new_manga('S6', '[{"url": "https://a.example"}]')$$, '23514', NULL, 'site without type is rejected');
SELECT throws_ok($$EXECUTE new_manga('S7', '["https://a.example"]')$$, '23514', NULL, 'bare string element is rejected');
SELECT throws_ok($$EXECUTE new_manga('S8', '[{"url": "https://a.example", "type": "primary"}, {"url": "https://b.example", "type": "primary"}]')$$, '23514', NULL, 'two primaries are rejected');
SELECT throws_ok($$INSERT INTO manga (title, sites) VALUES ('S9', NULL)$$, '23502', NULL, 'null sites is rejected');

-- 5 chapters
PREPARE progress(uuid, numeric) AS
    INSERT INTO user_progress (user_id, manga_id, last_chapter_read)
    SELECT $1, id, $2 FROM manga WHERE title = 'Test Manga';
SELECT throws_ok($$EXECUTE progress('00000000-0000-7000-8000-000000000001', -0.1)$$, '23514', NULL, 'negative chapter is rejected');
SELECT throws_ok($$EXECUTE progress('00000000-0000-7000-8000-000000000001', 12.25)$$, '23514', NULL, 'more than one decimal place is rejected');
SELECT throws_ok($$EXECUTE progress('00000000-0000-7000-8000-000000000001', 100000)$$, '23514', NULL, 'chapter >= 100000 is rejected');
EXECUTE progress('00000000-0000-7000-8000-000000000001', 703.7);
SELECT is(last_chapter_read, 703.7, 'fractional chapter round-trips')
FROM user_progress WHERE user_id = '00000000-0000-7000-8000-000000000001';

-- 6 one progress row per user+manga
SELECT throws_ok($$EXECUTE progress('00000000-0000-7000-8000-000000000001', 1)$$, '23505', NULL, 'duplicate progress row is rejected');

-- 7 defaults
INSERT INTO user_progress (user_id, manga_id)
SELECT '00000000-0000-7000-8000-000000000002', id FROM manga WHERE title = 'Test Manga';
SELECT results_eq(
    $$SELECT status, last_chapter_read, worth_reading FROM user_progress
      WHERE user_id = '00000000-0000-7000-8000-000000000002'$$,
    $$VALUES ('plan_to_read'::manga_status, 0::numeric, NULL::boolean)$$,
    'progress defaults: plan_to_read, chapter 0, no opinion');

-- 8 updated_at
UPDATE manga SET updated_at = '2000-01-01' WHERE title = 'Test Manga';
UPDATE manga SET sites = '[]' WHERE title = 'Test Manga';
SELECT is(updated_at, now(), 'manga.updated_at is bumped on update') FROM manga WHERE title = 'Test Manga';
UPDATE user_progress SET updated_at = '2000-01-01' WHERE user_id = '00000000-0000-7000-8000-000000000002';
UPDATE user_progress SET status = 'reading' WHERE user_id = '00000000-0000-7000-8000-000000000002';
SELECT is(updated_at, now(), 'user_progress.updated_at is bumped on update')
FROM user_progress WHERE user_id = '00000000-0000-7000-8000-000000000002';

-- 9 cascades
DELETE FROM auth.account WHERE id = '00000000-0000-7000-8000-000000000002';
SELECT is((SELECT count(*) FROM user_progress WHERE user_id = '00000000-0000-7000-8000-000000000002'), 0::bigint,
          'deleting an account deletes its progress');
DELETE FROM manga WHERE title = 'Test Manga';
SELECT is((SELECT count(*) FROM user_progress WHERE user_id = '00000000-0000-7000-8000-000000000001'), 0::bigint,
          'deleting a manga deletes its progress');

-- 10 account email
SELECT throws_ok($$INSERT INTO auth.account (email, password_hash) VALUES ('A@TEST.local', 'x')$$, '23505', NULL, 'duplicate email ignoring case is rejected');
SELECT throws_ok($$INSERT INTO auth.account (email, password_hash) VALUES ('not-an-email', 'x')$$, '23514', NULL, 'malformed email is rejected');
SELECT throws_ok($$INSERT INTO auth.account (email, password_hash) VALUES ('a b@test.local', 'x')$$, '23514', NULL, 'email with space is rejected');
SELECT ok((SELECT id FROM auth.account WHERE email = 'a@test.local') IS NOT NULL
          AND (SELECT count(*) FROM auth.account WHERE email = 'A@Test.Local') = 1, 'email lookup is case-insensitive');
WITH a AS (INSERT INTO auth.account (email, password_hash) VALUES ('c@test.local', 'x') RETURNING id)
SELECT is(uuid_extract_version(id)::int, 7, 'account ids are uuidv7') FROM a;

SELECT * FROM finish();
ROLLBACK;
