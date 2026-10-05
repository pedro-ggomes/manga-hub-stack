import { vi } from 'vitest';

export type Call = { method: string; path: string; body: unknown; auth: string | null };
type Reply = { status: number; body?: unknown };
type Handler = (call: Call) => Reply | Promise<Reply>;

/** Stub fetch at the boundary. Routes are matched by `METHOD /path` prefix (query included). */
export function stubApi(routes: Record<string, Handler>): Call[] {
  const calls: Call[] = [];
  vi.stubGlobal('fetch', vi.fn(async (url: string, init: RequestInit = {}) => {
    const method = init.method ?? 'GET';
    const path = url.replace(/^\/api/, '');
    const headers = new Headers(init.headers);
    const call: Call = { method, path, body: init.body ? JSON.parse(String(init.body)) : undefined, auth: headers.get('Authorization') };
    calls.push(call);
    const key = Object.keys(routes).find((k) => `${method} ${path}`.startsWith(k));
    if (!key) throw new Error(`unexpected request: ${method} ${path}`);
    const { status, body } = await routes[key](call);
    return new Response(body === undefined ? null : JSON.stringify(body), { status });
  }));
  return calls;
}

export const rows = [
  { manga_id: 1, status: 'reading', last_chapter_read: 1194, worth_reading: true,
    manga: { id: 1, title: 'One Piece', sites: [{ url: 'https://op.example/', type: 'primary' }] } },
  { manga_id: 2, status: 'reading', last_chapter_read: 703.7, worth_reading: true,
    manga: { id: 2, title: 'Kingdom', sites: [{ url: 'https://k.example/', type: 'primary' }, { url: 'https://k-alt.example/', type: 'alt' }] } },
  { manga_id: 3, status: 'plan_to_read', last_chapter_read: 0, worth_reading: null,
    manga: { id: 3, title: 'JJBA - Steel Ball Run', sites: [] } },
];

/** A promise you resolve from the test, to control when a stubbed response arrives. */
export function deferred<T>() {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}
