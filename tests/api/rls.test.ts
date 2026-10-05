import { before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { call, countStatuses, newUser, uniq, waitForApi } from './helpers.ts';

type Manga = { id: number; title: string; created_by: string; sites: unknown[] };
type Progress = { user_id: string; manga_id: number; last_chapter_read: number };

let alice: Awaited<ReturnType<typeof newUser>>;
let bob: Awaited<ReturnType<typeof newUser>>;

before(async () => {
  await waitForApi();
  [alice, bob] = await Promise.all([newUser(), newUser()]);
});

async function addManga(token: string, title = `Manga ${uniq()}`): Promise<Manga> {
  const res = await call('/manga', { method: 'POST', token, body: { title }, prefer: 'return=representation' });
  assert.equal(res.status, 201, await res.clone().text());
  return ((await res.json()) as Manga[])[0];
}

describe('catalog', () => {
  test('insert records the caller as created_by; everyone can read it (AC6, AC7)', async () => {
    const m = await addManga(alice.token);
    assert.equal(m.created_by, alice.id);
    const seen = (await (await call(`/manga?id=eq.${m.id}`, { token: bob.token })).json()) as Manga[];
    assert.equal(seen.length, 1);
  });

  test('title lookups ignore case', async () => {
    const m = await addManga(alice.token, `Case Test ${uniq()}`);
    const rows = (await (await call(`/manga?title=eq.${encodeURIComponent(m.title.toLowerCase())}`, { token: bob.token })).json()) as Manga[];
    assert.deepEqual(rows.map((r) => r.id), [m.id]);
  });

  test('20 concurrent inserts of one title: exactly one succeeds (AC7)', async () => {
    const title = `Race ${uniq()}`;
    const results = await Promise.all(Array.from({ length: 20 }, (_, i) =>
      call('/manga', { method: 'POST', token: i % 2 ? alice.token : bob.token, body: { title } })));
    assert.deepEqual(countStatuses(results.map((r) => r.status)), { 201: 1, 409: 19 });
    const rows = (await (await call(`/manga?title=eq.${encodeURIComponent(title)}`, { token: alice.token })).json()) as Manga[];
    assert.equal(rows.length, 1);
  });

  test("updating someone else's manga changes nothing (AC8)", async () => {
    const m = await addManga(alice.token);
    await call(`/manga?id=eq.${m.id}`, { method: 'PATCH', token: bob.token, body: { title: `Hijacked ${uniq()}` } });
    const [after] = (await (await call(`/manga?id=eq.${m.id}`, { token: alice.token })).json()) as Manga[];
    assert.equal(after.title, m.title);
  });

  test('creator can update; nobody can delete (AC8)', async () => {
    const m = await addManga(alice.token);
    const sites = [{ url: 'https://example.com/read', type: 'primary' }];
    assert.equal((await call(`/manga?id=eq.${m.id}`, { method: 'PATCH', token: alice.token, body: { sites } })).status, 204);
    assert.equal((await call(`/manga?id=eq.${m.id}`, { method: 'DELETE', token: alice.token })).status, 403);
  });

  test('invalid sites are a 400 (constraint surfaces through the API)', async () => {
    const res = await call('/manga', { method: 'POST', token: alice.token, body: { title: `Bad ${uniq()}`, sites: [{ url: 'ftp://x' }] } });
    assert.equal(res.status, 400);
  });

  test('client cannot set created_by or id (AC9)', async () => {
    const spoof = await call('/manga', { method: 'POST', token: alice.token, body: { title: `Spoof ${uniq()}`, created_by: bob.id } });
    assert.equal(spoof.status, 403);
    // ALWAYS identity rejects an explicit id (400) before the privilege check (403); either is a refusal
    const title = `Spoof ${uniq()}`;
    const id = await call('/manga', { method: 'POST', token: alice.token, body: { id: 999999, title } });
    assert.ok([400, 403].includes(id.status), `got ${id.status}`);
    assert.deepEqual(await (await call(`/manga?title=eq.${encodeURIComponent(title)}`, { token: alice.token })).json(), []);
  });
});

describe('progress', () => {
  test('progress is per user: own rows only, for every verb (AC6, AC9)', async () => {
    const m = await addManga(alice.token);
    for (const u of [alice, bob]) {
      const res = await call('/user_progress', { method: 'POST', token: u.token, body: { manga_id: m.id, last_chapter_read: 5 }, prefer: 'return=representation' });
      assert.equal(res.status, 201);
      assert.equal(((await res.json()) as Progress[])[0].user_id, u.id);
    }

    const bobSees = (await (await call(`/user_progress?manga_id=eq.${m.id}`, { token: bob.token })).json()) as Progress[];
    assert.deepEqual(bobSees.map((p) => p.user_id), [bob.id]);

    // bob aims at alice's row explicitly: nothing happens
    await call(`/user_progress?user_id=eq.${alice.id}&manga_id=eq.${m.id}`, { method: 'PATCH', token: bob.token, body: { last_chapter_read: 99 } });
    await call(`/user_progress?user_id=eq.${alice.id}`, { method: 'DELETE', token: bob.token });
    const [mine] = (await (await call(`/user_progress?manga_id=eq.${m.id}`, { token: alice.token })).json()) as Progress[];
    assert.equal(Number(mine.last_chapter_read), 5);

    // alice updates and deletes her own
    assert.equal((await call(`/user_progress?manga_id=eq.${m.id}`, { method: 'PATCH', token: alice.token, body: { last_chapter_read: 6.5 } })).status, 204);
    assert.equal((await call(`/user_progress?manga_id=eq.${m.id}`, { method: 'DELETE', token: alice.token })).status, 204);
    assert.deepEqual(await (await call(`/user_progress?manga_id=eq.${m.id}`, { token: alice.token })).json(), []);
  });

  test('client-supplied user_id is refused (AC9)', async () => {
    const m = await addManga(alice.token);
    const res = await call('/user_progress', { method: 'POST', token: alice.token, body: { manga_id: m.id, user_id: bob.id } });
    assert.equal(res.status, 403);
  });

  test('tracking the same manga twice is 409', async () => {
    const m = await addManga(alice.token);
    await call('/user_progress', { method: 'POST', token: alice.token, body: { manga_id: m.id } });
    assert.equal((await call('/user_progress', { method: 'POST', token: alice.token, body: { manga_id: m.id } })).status, 409);
  });
});
