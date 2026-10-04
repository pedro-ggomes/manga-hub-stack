export const STATUSES = ['reading', 'completed', 'on_hold', 'dropped', 'plan_to_read'] as const;
export type Status = (typeof STATUSES)[number];
export type Site = { url: string; type: 'primary' | 'alt' };
export type Manga = { id: number; title: string; sites: Site[] };
export type Progress = {
  manga_id: number;
  status: Status;
  last_chapter_read: number;
  worth_reading: boolean | null;
  manga: Manga;
};

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

type Options = { method?: string; body?: unknown; token?: string | null; prefer?: string };

/** Calls PostgREST through the Vite proxy. Throws ApiError with PostgREST's message. */
export async function api<T>(path: string, { method = 'GET', body, token, prefer }: Options = {}): Promise<T> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (prefer) headers.Prefer = prefer;
  const res = await fetch('/api' + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) throw new ApiError(res.status, data?.message ?? res.statusText);
  return data as T;
}

export const statusLabel = (s: Status): string => s[0].toUpperCase() + s.slice(1).replaceAll('_', ' ');
