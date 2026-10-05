import { before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { call, claims, countStatuses, newUser, sign, signatureValid, uniq, waitForApi } from './helpers.ts';

before(waitForApi);

describe('signup', () => {
  test('returns a token PostgREST-compatible clients can verify (AC1)', async () => {
    const user = await newUser();
    assert.ok(signatureValid(user.token), 'signature verifies with JWT_SECRET');
    const c = claims(user.token);
    assert.equal(c.role, 'authenticated');
    assert.match(String(c.sub), /^[0-9a-f-]{36}$/);
    assert.ok(Number(c.exp) > Date.now() / 1000);
  });

  test('rejects a short password and a malformed email with 400 (AC2)', async () => {
    const short = await call('/rpc/signup', { method: 'POST', body: { email: `s-${uniq()}@test.local`, password: 'elevenchars' } });
    assert.equal(short.status, 400);
    const bad = await call('/rpc/signup', { method: 'POST', body: { email: 'not-an-email', password: 'correct-horse-battery' } });
    assert.equal(bad.status, 400);
  });

  test('duplicate email (any case) is 409 (AC3)', async () => {
    const user = await newUser();
    const res = await call('/rpc/signup', { method: 'POST', body: { email: user.email.toUpperCase(), password: user.password } });
    assert.equal(res.status, 409);
  });

  test('10 concurrent signups for one email: exactly one succeeds (AC3)', async () => {
    const email = `race-${uniq()}@test.local`;
    const results = await Promise.all(Array.from({ length: 10 }, () =>
      call('/rpc/signup', { method: 'POST', body: { email, password: 'correct-horse-battery' } })));
    assert.deepEqual(countStatuses(results.map((r) => r.status)), { 200: 1, 409: 9 });
  });
});

describe('login', () => {
  test('correct credentials return a valid token for the same account (AC4)', async () => {
    const user = await newUser();
    const res = await call('/rpc/login', { method: 'POST', body: { email: user.email, password: user.password } });
    assert.equal(res.status, 200);
    const { token } = (await res.json()) as { token: string };
    assert.equal(claims(token).sub, user.id);
  });

  test('wrong password and unknown email get the same 401 (AC4)', async () => {
    const user = await newUser();
    const wrong = await call('/rpc/login', { method: 'POST', body: { email: user.email, password: 'wrong-password-123' } });
    const unknown = await call('/rpc/login', { method: 'POST', body: { email: `nobody-${uniq()}@test.local`, password: 'wrong-password-123' } });
    assert.equal(wrong.status, 401);
    assert.equal(unknown.status, 401);
    assert.deepEqual(await wrong.json(), await unknown.json());
  });
});

describe('without a token (AC5)', () => {
  for (const path of ['/manga', '/user_progress']) {
    test(`GET ${path} is 401`, async () => assert.equal((await call(path)).status, 401));
  }
  for (const fn of ['crypt', 'current_user_id', 'is_valid_sites', 'token_for', 'base64url']) {
    test(`/rpc/${fn} is not exposed`, async () => {
      const res = await call(`/rpc/${fn}`, { method: 'POST', body: {} });
      assert.ok([401, 404].includes(res.status), `got ${res.status}`);
    });
  }
});

describe('bad tokens (AC10)', () => {
  test('expired token is 401, while the same token unexpired is accepted', async () => {
    const user = await newUser();
    const now = Math.floor(Date.now() / 1000);
    const token = (exp: number) => sign({ sub: user.id, role: 'authenticated', iat: now - 7200, exp });
    assert.equal((await call('/manga', { token: token(now + 3600) })).status, 200, 'positive control');
    assert.equal((await call('/manga', { token: token(now - 3600) })).status, 401);
  });

  test('token signed with another secret is 401', async () => {
    const user = await newUser();
    const res = await call('/manga', { token: sign({ ...claims(user.token) }, 'x'.repeat(64)) });
    assert.equal(res.status, 401);
  });
});
