BEGIN;
SELECT plan(19);

INSERT INTO auth.account (id, email, password_hash) VALUES
    ('00000000-0000-7000-8000-00000000000a', 'alice@test.local', 'x'),
    ('00000000-0000-7000-8000-00000000000b', 'bob@test.local', 'x');
INSERT INTO manga (title, created_by) VALUES
    ('Alice Manga', '00000000-0000-7000-8000-00000000000a'),
    ('Bob Manga', '00000000-0000-7000-8000-00000000000b');
INSERT INTO user_progress (user_id, manga_id, last_chapter_read)
SELECT u, m.id, 5 FROM manga m,
       unnest(ARRAY['00000000-0000-7000-8000-00000000000a', '00000000-0000-7000-8000-00000000000b']::uuid[]) AS u
WHERE m.title = 'Bob Manga';

-- act as a user exactly as PostgREST does: role + request.jwt.claims
CREATE FUNCTION pg_temp.act_as(uid uuid) RETURNS void LANGUAGE sql AS $$
    SELECT set_config('role', 'authenticated', true),
           set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true)
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act_as(uuid) TO authenticated;

SELECT pg_temp.act_as('00000000-0000-7000-8000-00000000000a');

-- 6 reads
SELECT is((SELECT count(*) FROM manga WHERE title IN ('Alice Manga', 'Bob Manga')), 2::bigint, 'user sees every catalog row');
SELECT is((SELECT array_agg(DISTINCT user_id) FROM user_progress), ARRAY['00000000-0000-7000-8000-00000000000a'::uuid], 'user sees only own progress');

-- 7 insert manga
INSERT INTO manga (title) VALUES ('Alice Second');
SELECT is((SELECT created_by FROM manga WHERE title = 'Alice Second'), '00000000-0000-7000-8000-00000000000a'::uuid, 'created_by is the caller');
SELECT throws_ok($$INSERT INTO manga (title, created_by) VALUES ('Spoof', '00000000-0000-7000-8000-00000000000b')$$, '42501', NULL, 'client cannot set created_by');
SELECT throws_ok($$INSERT INTO manga (id, title) OVERRIDING SYSTEM VALUE VALUES (999999, 'Spoof')$$, '42501', NULL, 'client cannot set id');

-- 8 update / delete manga
UPDATE manga SET sites = '[{"url": "https://alice.example", "type": "primary"}]' WHERE title = 'Alice Manga';
SELECT is((SELECT sites ->> 0 IS NOT NULL FROM manga WHERE title = 'Alice Manga'), true, 'creator can update own manga');
UPDATE manga SET title = 'Hijacked' WHERE title = 'Bob Manga';
SELECT is((SELECT count(*) FROM manga WHERE title = 'Bob Manga'), 1::bigint, 'updating another user''s manga changes nothing');
SELECT throws_ok($$UPDATE manga SET created_by = '00000000-0000-7000-8000-00000000000a' WHERE title = 'Alice Manga'$$, '42501', NULL, 'client cannot change created_by');
SELECT throws_ok($$DELETE FROM manga WHERE title = 'Alice Manga'$$, '42501', NULL, 'manga cannot be deleted through the API');

-- 9 progress
INSERT INTO user_progress (manga_id, status) SELECT id, 'reading' FROM manga WHERE title = 'Alice Manga';
SELECT is((SELECT user_id FROM user_progress JOIN manga ON manga.id = manga_id WHERE title = 'Alice Manga'),
          '00000000-0000-7000-8000-00000000000a'::uuid, 'progress user_id defaults to the caller');
SELECT throws_ok($$INSERT INTO user_progress (user_id, manga_id) SELECT '00000000-0000-7000-8000-00000000000b', id FROM manga WHERE title = 'Alice Manga'$$,
                 '42501', NULL, 'client cannot set user_id');
UPDATE user_progress SET last_chapter_read = 99 WHERE manga_id = (SELECT id FROM manga WHERE title = 'Bob Manga');
DELETE FROM user_progress WHERE manga_id = (SELECT id FROM manga WHERE title = 'Alice Manga');
SELECT throws_ok($$UPDATE user_progress SET manga_id = 1$$, '42501', NULL, 'client cannot move progress to another manga');

SELECT set_config('role', 'none', true);  -- back to the test owner to check what really happened
RESET ROLE;
SELECT is((SELECT last_chapter_read FROM user_progress JOIN manga ON manga.id = manga_id
           WHERE title = 'Bob Manga' AND user_id = '00000000-0000-7000-8000-00000000000a'), 99::numeric, 'user updated own progress');
SELECT is((SELECT last_chapter_read FROM user_progress JOIN manga ON manga.id = manga_id
           WHERE title = 'Bob Manga' AND user_id = '00000000-0000-7000-8000-00000000000b'), 5::numeric, 'other user''s progress is untouched');
SELECT is((SELECT count(*) FROM user_progress JOIN manga ON manga.id = manga_id WHERE title = 'Alice Manga'), 0::bigint, 'user deleted own progress');

-- bob cannot touch alice's row even by naming it
SELECT pg_temp.act_as('00000000-0000-7000-8000-00000000000b');
DELETE FROM user_progress WHERE user_id = '00000000-0000-7000-8000-00000000000a';
RESET ROLE;
SELECT is((SELECT count(*) FROM user_progress WHERE user_id = '00000000-0000-7000-8000-00000000000a'), 1::bigint, 'deleting another user''s progress removes nothing');

-- anonymous claims: no sub → sees nothing, can't write
SELECT set_config('role', 'authenticated', true), set_config('request.jwt.claims', '{"role": "authenticated"}', true);
SELECT is((SELECT count(*) FROM user_progress), 0::bigint, 'token without sub sees no progress');
SELECT throws_ok($$INSERT INTO user_progress (manga_id) SELECT id FROM manga WHERE title = 'Alice Manga'$$, '42501', NULL, 'token without sub cannot insert progress (RLS refuses before NOT NULL)');
RESET ROLE;
SELECT ok(NOT has_table_privilege('authenticated', 'auth.account', 'SELECT'), 'authenticated cannot read accounts');

SELECT * FROM finish();
ROLLBACK;
