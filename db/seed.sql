-- Dev seed: the reading list as of 2026-10-04, owned by a demo account.
-- Idempotent. Run with `make seed` (one transaction). The demo password is read from
-- the DEMO_PASSWORD env var so it never appears on a command line or in output.
\getenv demo_password DEMO_PASSWORD
SELECT set_config('seed.demo_password', :'demo_password', true) IS NOT NULL AS seed_password_set \gset

DO $$
BEGIN
    IF length(current_setting('seed.demo_password')) < 12 THEN
        RAISE EXCEPTION 'DEMO_PASSWORD must be at least 12 characters';
    END IF;
END
$$;

INSERT INTO auth.account (email, password_hash)
VALUES ('demo@manga.local', crypt(current_setting('seed.demo_password'), gen_salt('bf', 12)))
ON CONFLICT (email) DO UPDATE SET password_hash = excluded.password_hash;

SET LOCAL client_min_messages = warning;
DROP TABLE IF EXISTS pg_temp.seed;
CREATE TEMP TABLE seed (title text, status manga_status, chapter numeric, sites jsonb, worth_reading boolean);
INSERT INTO seed VALUES
    ('Kagurabachi',        'reading', 111,   '[{"url": "https://ww1.readkagurabachimanga.com/", "type": "primary"}]', true),
    ('One Piece',          'reading', 1194,  '[{"url": "https://ww11.readonepiece.com/", "type": "primary"}]', true),
    ('Hunter x Hunter',    'reading', 420,   '[{"url": "https://w20.read-hxh.com/", "type": "primary"}]', true),
    ('Sousou no Frieren',  'reading', 147,   '[{"url": "https://www.frierenmangafree.com/", "type": "primary"}]', true),
    ('Chainsaw Man',       'reading', 228,   '[{"url": "https://ww5.readchainsawman.com/", "type": "primary"}]', true),
    ('Murim Login',        'reading', 250,   '[{"url": "https://demonicscans.org/manga/Murim-Login", "type": "primary"}]', true),
    ('Sakamoto Days',      'reading', 260,   '[{"url": "https://ww1.readsakadays.com/", "type": "primary"}]', true),
    ('One-Punch Man',      'reading', 240,   '[{"url": "https://mangapill.com/manga/3262/one-punch-man", "type": "primary"}]', true),
    ('Versus',             'reading', 36,    '[{"url": "https://mangapill.com/manga/6859/versus", "type": "primary"},
                                               {"url": "https://cubari.moe/read/mangakatana/aHR0cHM6Ly9tYW5nYWthdGFuYS5jb20vbWFuZ2EvdmVyc3VzLjI2NjM4Lw/", "type": "alt"}]', true),
    ('JJK Modulo',         'reading', 25,    '[{"url": "https://jujutsukaisenmodulo.com/", "type": "primary"}]', true),
    ('Undead Unluck',      'reading', 167,   '[{"url": "https://readundeadunluck.com/", "type": "primary"}]', true),
    ('Bug Ego',            'reading', 16,    '[{"url": "https://cubari.moe/read/weebcentral/01JEV1W0KZGH1N314XPA83K4DV/", "type": "primary"}]', true),
    ('Usogui',             'reading', 244,   '[{"url": "https://cubari.moe/read/weebcentral/01J76XY80XFFFA1MM9SCZ2725Z/", "type": "primary"}]', true),
    ('The Nito Exorcists', 'reading', 55,    '[{"url": "https://cubari.moe/read/mangakatana/aHR0cHM6Ly9tYW5nYWthdGFuYS5jb20vbWFuZ2EvdGhlLW5pdG8tZXhvcmNpc3RzLjI3NjQ5Lw/", "type": "primary"}]', true),
    ('Yomi no Tsugai',     'reading', 56,    '[{"url": "https://cubari.moe/read/weebcentral/01J76XYF9WXVB2VVMCYXHD1P1E/", "type": "primary"}]', true),
    ('Alien Headbutt',     'reading', 14,    '[{"url": "https://cubari.moe/read/weebcentral/01KHV2RFN0PAC2KDDNXZ4X5683/", "type": "primary"}]', true),
    ('Kingdom',            'reading', 703.7, '[{"url": "https://cubari.moe/read/weebcentral/01J76XY7VSG3R5ANYPDWTXDVP6/", "type": "primary"}]', true),
    ('JJBA - Steel Ball Run', 'plan_to_read', 0, '[{"url": "https://mangadex.org/title/1044287a-73df-48d0-b0b2-5327f32dd651/jojo-no-kimyou-na-bouken-part-7-steel-ball-run-color-ban", "type": "primary"}]', NULL);

INSERT INTO manga (title, sites)
SELECT title, sites FROM seed
ON CONFLICT (title) DO NOTHING;

INSERT INTO user_progress (user_id, manga_id, status, last_chapter_read, worth_reading)
SELECT a.id, m.id, s.status, s.chapter, s.worth_reading
FROM seed s
JOIN manga m ON m.title = s.title
CROSS JOIN auth.account a
WHERE a.email = 'demo@manga.local'
ON CONFLICT (user_id, manga_id) DO NOTHING;
