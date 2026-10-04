import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import App from './App.tsx';
import { deferred, rows, stubApi, type Call } from './test-utils.ts';

beforeEach(() => localStorage.setItem('token', 'tok-1'));
afterEach(() => { cleanup(); vi.unstubAllGlobals(); vi.restoreAllMocks(); localStorage.clear(); });

const ok = () => ({ status: 204 });

async function open(routes: Parameters<typeof stubApi>[0] = {}): Promise<Call[]> {
  const calls = stubApi({ 'GET /user_progress': () => ({ status: 200, body: structuredClone(rows) }), ...routes });
  render(<App />);
  await screen.findByText('One Piece');
  return calls;
}
const card = (title: string) => screen.getByRole('article', { name: title });
const chapterInput = (title: string) => within(card(title)).getByLabelText(/last chapter read/i) as HTMLInputElement;
const writes = (calls: Call[]) => calls.filter((c) => c.method !== 'GET');

test('AC1: +1 moves to the next whole chapter for that manga only', async () => {
  const calls = await open({ 'PATCH /user_progress': ok });
  await userEvent.click(within(card('One Piece')).getByRole('button', { name: '+1' }));
  expect(chapterInput('One Piece').value).toBe('1195');
  await userEvent.click(within(card('Kingdom')).getByRole('button', { name: '+1' }));
  expect(chapterInput('Kingdom').value).toBe('704');
  expect(writes(calls)).toEqual([
    expect.objectContaining({ method: 'PATCH', path: '/user_progress?manga_id=eq.1', body: { last_chapter_read: 1195 } }),
    expect.objectContaining({ method: 'PATCH', path: '/user_progress?manga_id=eq.2', body: { last_chapter_read: 704 } }),
  ]);
});

test('AC2: typing a chapter and pressing Enter saves it', async () => {
  const calls = await open({ 'PATCH /user_progress': ok });
  await userEvent.clear(chapterInput('One Piece'));
  await userEvent.type(chapterInput('One Piece'), '250.5{Enter}');
  expect(writes(calls)).toEqual([expect.objectContaining({ path: '/user_progress?manga_id=eq.1', body: { last_chapter_read: 250.5 } })]);
});

test('AC3: changing status saves it', async () => {
  const calls = await open({ 'PATCH /user_progress': ok });
  await userEvent.selectOptions(within(card('Kingdom')).getByLabelText(/status/i), 'completed');
  expect(writes(calls)).toEqual([expect.objectContaining({ path: '/user_progress?manga_id=eq.2', body: { status: 'completed' } })]);
});

test('AC4: worth-reading cycles unset → yes → no → unset', async () => {
  const calls = await open({ 'PATCH /user_progress': ok });
  const toggle = () => within(card('JJBA - Steel Ball Run')).getByRole('button', { name: /worth reading/i });
  for (let i = 0; i < 3; i++) await userEvent.click(toggle());
  expect(writes(calls).map((c) => c.body)).toEqual([{ worth_reading: true }, { worth_reading: false }, { worth_reading: null }]);
});

test('AC5: a refused update reverts and shows the error', async () => {
  await open({ 'PATCH /user_progress': () => ({ status: 400, body: { message: 'violates check constraint' } }) });
  await userEvent.click(within(card('One Piece')).getByRole('button', { name: '+1' }));
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'violates check constraint');
  expect(chapterInput('One Piece').value).toBe('1194');
});

const newRow = { manga_id: 10, status: 'reading', last_chapter_read: 0, worth_reading: null,
  manga: { id: 10, title: 'Dandadan', sites: [{ url: 'https://d.example/', type: 'primary' }] } };

async function addTitle(title: string, url = '') {
  await userEvent.click(screen.getByRole('button', { name: /add title/i }));
  await userEvent.type(screen.getByLabelText(/^title/i), title);
  if (url) await userEvent.type(screen.getByLabelText(/primary url/i), url);
  await userEvent.click(screen.getByRole('button', { name: /^add$/i }));
}

test('AC6: adding a new title creates it, tracks it as reading, and lists it', async () => {
  const calls = await open({
    'GET /manga?select=title': () => ({ status: 200, body: [{ title: 'One Piece' }] }),
    'POST /manga': () => ({ status: 201, body: [newRow.manga] }),
    'POST /user_progress': () => ({ status: 201, body: [newRow] }),
  });
  await addTitle('Dandadan', 'https://d.example/');
  expect(await screen.findByRole('article', { name: 'Dandadan' })).toBeTruthy();
  expect(writes(calls)).toEqual([
    expect.objectContaining({ method: 'POST', path: '/manga', body: { title: 'Dandadan', sites: [{ url: 'https://d.example/', type: 'primary' }] } }),
    expect.objectContaining({ method: 'POST', body: { manga_id: 10, status: 'reading' } }),
  ]);
});

test('AC7: a title already in the catalog is tracked instead of failing', async () => {
  const calls = await open({
    'GET /manga?select=title': () => ({ status: 200, body: [] }),
    'POST /manga': () => ({ status: 409, body: { message: 'duplicate key value violates unique constraint' } }),
    'GET /manga?select=id,title,sites&title=eq.dandadan': () => ({ status: 200, body: [newRow.manga] }),
    'POST /user_progress': () => ({ status: 201, body: [newRow] }),
  });
  await addTitle('dandadan');
  expect(await screen.findByRole('article', { name: 'Dandadan' })).toBeTruthy();
  expect(screen.queryByRole('alert')).toBeNull();
  expect(writes(calls).at(-1)?.body).toEqual({ manga_id: 10, status: 'reading' });
});

test('AC6: adding a title already in my library says so', async () => {
  await open({
    'GET /manga?select=title': () => ({ status: 200, body: [] }),
    'POST /manga': () => ({ status: 409, body: { message: 'duplicate' } }),
    'GET /manga?select=id,title,sites&title=eq.Kingdom': () => ({ status: 200, body: [rows[1].manga] }),
    'POST /user_progress': () => ({ status: 409, body: { message: 'duplicate' } }),
  });
  await addTitle('Kingdom');
  expect((await screen.findByRole('alert')).textContent).toMatch(/already in your library/i);
});

test('AC8: confirmed untrack deletes the row and removes the card; cancel does nothing', async () => {
  const calls = await open({ 'DELETE /user_progress': ok });
  const confirm = vi.spyOn(window, 'confirm').mockReturnValueOnce(false).mockReturnValueOnce(true);
  await userEvent.click(within(card('Kingdom')).getByRole('button', { name: /untrack/i }));
  expect(writes(calls)).toEqual([]);
  await userEvent.click(within(card('Kingdom')).getByRole('button', { name: /untrack/i }));
  expect(screen.queryByRole('article', { name: 'Kingdom' })).toBeNull();
  expect(writes(calls)).toEqual([expect.objectContaining({ method: 'DELETE', path: '/user_progress?manga_id=eq.2' })]);
  expect(confirm).toHaveBeenCalledTimes(2);
});

test('review: a failed update reverts only its own field, not a later successful one', async () => {
  const first = deferred<{ status: number; body?: unknown }>();
  let n = 0;
  await open({ 'PATCH /user_progress': () => (n++ === 0 ? first.promise : { status: 204 }) });
  await userEvent.click(within(card('Kingdom')).getByRole('button', { name: '+1' }));
  await userEvent.selectOptions(within(card('Kingdom')).getByLabelText(/status/i), 'completed');
  first.resolve({ status: 400, body: { message: 'nope' } });
  await screen.findByRole('alert');
  expect(chapterInput('Kingdom').value).toBe('703.7');
  expect((within(card('Kingdom')).getByLabelText(/status/i) as HTMLSelectElement).value).toBe('completed');
});

test('review: rapid +1 clicks reach the server in order (one PATCH in flight per title)', async () => {
  const first = deferred<{ status: number; body?: unknown }>();
  let n = 0;
  const calls = await open({ 'PATCH /user_progress': () => (n++ === 0 ? first.promise : { status: 204 }) });
  const plus = () => within(card('One Piece')).getByRole('button', { name: '+1' });
  await userEvent.click(plus());
  await userEvent.click(plus());
  expect(writes(calls).map((c) => c.body)).toEqual([{ last_chapter_read: 1195 }]);
  first.resolve({ status: 204 });
  await vi.waitFor(() => expect(writes(calls).map((c) => c.body)).toEqual([{ last_chapter_read: 1195 }, { last_chapter_read: 1196 }]));
  expect(chapterInput('One Piece').value).toBe('1196');
});

test('review: a failed untrack puts the card back where it was', async () => {
  await open({ 'DELETE /user_progress': () => ({ status: 500, body: { message: 'boom' } }) });
  vi.spyOn(window, 'confirm').mockReturnValue(true);
  await userEvent.click(within(card('Kingdom')).getByRole('button', { name: /untrack/i }));
  await screen.findByRole('alert');
  expect(screen.getAllByRole('article').map((a) => a.getAttribute('aria-labelledby'))).toEqual(['manga-1', 'manga-2', 'manga-3']);
});

test('review: no Add button until the library has loaded', async () => {
  stubApi({ 'GET /user_progress': () => ({ status: 500, body: { message: 'db down' } }) });
  render(<App />);
  await screen.findByRole('alert');
  expect(screen.queryByRole('button', { name: /add title/i })).toBeNull();
});

test('review: clearing the chapter box and leaving it restores the saved value', async () => {
  const calls = await open();
  await userEvent.clear(chapterInput('One Piece'));
  await userEvent.tab();
  expect(chapterInput('One Piece').value).toBe('1194');
  expect(writes(calls)).toEqual([]);
});

test('review: Add is disabled while a submit is in flight', async () => {
  const created = deferred<{ status: number; body?: unknown }>();
  await open({
    'GET /manga?select=title': () => ({ status: 200, body: [] }),
    'POST /manga': () => created.promise,
    'POST /user_progress': () => ({ status: 201, body: [newRow] }),
  });
  await addTitle('Dandadan');
  expect((screen.getByRole('button', { name: /^add/i }) as HTMLButtonElement).disabled).toBe(true);
  created.resolve({ status: 201, body: [newRow.manga] });
  expect(await screen.findByRole('article', { name: 'Dandadan' })).toBeTruthy();
});
