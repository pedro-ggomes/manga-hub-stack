// Shared helpers for HTTP tests. They run against `postgrest-test` (the throwaway DB).
import { createHmac, randomUUID } from 'node:crypto';

export const API = process.env.API_URL ?? 'http://127.0.0.1:3001';
const SECRET = process.env.JWT_SECRET;
if (!SECRET) throw new Error('JWT_SECRET must be set (make exports it from .env)');

export const uniq = (): string => randomUUID().slice(0, 8);

export async function waitForApi(): Promise<void> {
  for (let i = 0; i < 60; i++) {
    try {
      if ((await fetch(API + '/')).status < 500) return;
    } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`API at ${API} did not become ready`);
}

export function call(path: string, init: { method?: string; body?: unknown; token?: string; prefer?: string } = {}) {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (init.token) headers.Authorization = `Bearer ${init.token}`;
  if (init.prefer) headers.Prefer = init.prefer;
  return fetch(API + path, {
    method: init.method ?? 'GET',
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
}

export async function newUser(): Promise<{ email: string; password: string; token: string; id: string }> {
  const email = `user-${uniq()}@test.local`;
  const password = 'correct-horse-battery';
  const res = await call('/rpc/signup', { method: 'POST', body: { email, password } });
  if (res.status !== 200) throw new Error(`signup failed: ${res.status} ${await res.text()}`);
  const { token } = (await res.json()) as { token: string };
  return { email, password, token, id: claims(token).sub as string };
}

const b64url = (b: Buffer | string): string => Buffer.from(b).toString('base64url');

export function sign(payload: object, secret = SECRET): string {
  const input = `${b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }))}.${b64url(JSON.stringify(payload))}`;
  return `${input}.${createHmac('sha256', secret).update(input).digest('base64url')}`;
}

export function claims(token: string): Record<string, unknown> {
  return JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString());
}

export function signatureValid(token: string, secret = SECRET): boolean {
  const [h, p, s] = token.split('.');
  return createHmac('sha256', secret).update(`${h}.${p}`).digest('base64url') === s;
}

export const countStatuses = (statuses: number[]): Record<number, number> =>
  statuses.reduce<Record<number, number>>((acc, s) => ({ ...acc, [s]: (acc[s] ?? 0) + 1 }), {});
