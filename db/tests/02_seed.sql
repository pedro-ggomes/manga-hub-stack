-- Loads the seed itself, twice and with two passwords, to prove idempotency.
BEGIN;
\setenv DEMO_PASSWORD first-password-123
\i /db/seed.sql
\setenv DEMO_PASSWORD second-password-456
\i /db/seed.sql

SELECT plan(7);

SELECT is((SELECT count(*) FROM manga), 18::bigint, '18 titles after seeding twice');
SELECT is((SELECT count(*) FROM user_progress p JOIN auth.account a ON a.id = p.user_id
           WHERE a.email = 'demo@manga.local'), 18::bigint, 'demo user has 18 progress rows after seeding twice');
SELECT is((SELECT last_chapter_read FROM user_progress JOIN manga ON manga.id = manga_id
           WHERE title = 'Kingdom'), 703.7, 'Kingdom is at 703.7');
SELECT results_eq(
    $$SELECT status::text, worth_reading FROM user_progress JOIN manga ON manga.id = manga_id
      WHERE title = 'JJBA - Steel Ball Run'$$,
    $$VALUES ('plan_to_read', NULL::boolean)$$,
    'Steel Ball Run is plan_to_read with no opinion');
SELECT is((SELECT jsonb_array_length(sites) FROM manga WHERE title = 'Versus'), 2, 'Versus keeps its alt site');
SELECT ok((SELECT password_hash LIKE '$2%' FROM auth.account WHERE email = 'demo@manga.local'),
          'demo password is stored as a bcrypt hash');
SELECT ok((SELECT password_hash = crypt('second-password-456', password_hash) FROM auth.account
           WHERE email = 'demo@manga.local'), 're-seeding applies the new DEMO_PASSWORD');

SELECT * FROM finish();
ROLLBACK;
