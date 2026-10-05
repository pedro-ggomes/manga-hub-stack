import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import App from './App.tsx';
import { rows, stubApi } from './test-utils.ts';

beforeEach(() => localStorage.clear());
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

const signIn = async (email = 'demo@manga.local', password = 'demo-password-1') => {
  await userEvent.type(screen.getByLabelText(/email/i), email);
  await userEvent.type(screen.getByLabelText(/password/i), password);
  await userEvent.click(screen.getByRole('button', { name: /sign in/i }));
};

test('AC1: no token shows the sign-in form', () => {
  render(<App />);
  expect(screen.getByRole('button', { name: /sign in/i })).toBeTruthy();
});

test('AC2: valid sign-in stores the token and shows the library', async () => {
  const calls = stubApi({
    'POST /rpc/login': () => ({ status: 200, body: { token: 'tok-1' } }),
    'GET /user_progress': () => ({ status: 200, body: rows }),
  });
  render(<App />);
  await signIn();
  expect(await screen.findByText('One Piece')).toBeTruthy();
  expect(localStorage.getItem('token')).toBe('tok-1');
  expect(calls[0].body).toEqual({ email: 'demo@manga.local', password: 'demo-password-1' });
  expect(calls[1].auth).toBe('Bearer tok-1');
});

test('AC3: failed sign-in shows the API message and stays on the form', async () => {
  stubApi({ 'POST /rpc/login': () => ({ status: 401, body: { message: 'invalid email or password' } }) });
  render(<App />);
  await signIn();
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'invalid email or password');
  expect(localStorage.getItem('token')).toBeNull();
});

test('AC4: "Create account" calls signup', async () => {
  const calls = stubApi({
    'POST /rpc/signup': () => ({ status: 200, body: { token: 'tok-new' } }),
    'GET /user_progress': () => ({ status: 200, body: [] }),
  });
  render(<App />);
  await userEvent.click(screen.getByRole('button', { name: /create account/i }));
  await userEvent.type(screen.getByLabelText(/email/i), 'new@manga.local');
  await userEvent.type(screen.getByLabelText(/password/i), 'a-long-password');
  await userEvent.click(screen.getByRole('button', { name: /sign up/i }));
  expect(await screen.findByText(/nothing tracked yet/i)).toBeTruthy();
  expect(calls[0].path).toBe('/rpc/signup');
});

const openLibrary = async () => {
  localStorage.setItem('token', 'tok-1');
  stubApi({ 'GET /user_progress': () => ({ status: 200, body: rows }) });
  render(<App />);
  await screen.findByText('One Piece');
};

test('AC5: each title shows status, chapter and its site links', async () => {
  await openLibrary();
  const kingdom = screen.getByRole('article', { name: 'Kingdom' });
  expect((within(kingdom).getByLabelText(/last chapter read/i) as HTMLInputElement).value).toBe('703.7');
  expect((within(kingdom).getByLabelText(/status/i) as HTMLSelectElement).value).toBe('reading');
  const read = within(kingdom).getByRole('link', { name: /read/i });
  expect(read.getAttribute('href')).toBe('https://k.example/');
  expect(read.getAttribute('target')).toBe('_blank');
  expect(read.getAttribute('rel')).toContain('noopener');
  expect(within(kingdom).getByRole('link', { name: /alt/i }).getAttribute('href')).toBe('https://k-alt.example/');
  expect(within(screen.getByRole('article', { name: 'JJBA - Steel Ball Run' })).queryAllByRole('link')).toEqual([]);
});

test('AC6: status filter shows only that status, with counts', async () => {
  await openLibrary();
  await userEvent.click(screen.getByRole('button', { name: /plan to read \(1\)/i }));
  expect(screen.queryByText('One Piece')).toBeNull();
  expect(screen.getByText('JJBA - Steel Ball Run')).toBeTruthy();
  await userEvent.click(screen.getByRole('button', { name: /all \(3\)/i }));
  expect(screen.getByText('One Piece')).toBeTruthy();
});

test('AC7: search filters titles ignoring case', async () => {
  await openLibrary();
  await userEvent.type(screen.getByRole('searchbox'), 'kING');
  expect(screen.getByText('Kingdom')).toBeTruthy();
  expect(screen.queryByText('One Piece')).toBeNull();
});

test('AC8: sign out clears the token', async () => {
  await openLibrary();
  await userEvent.click(screen.getByRole('button', { name: /sign out/i }));
  expect(localStorage.getItem('token')).toBeNull();
  expect(screen.getByRole('button', { name: /sign in/i })).toBeTruthy();
});

test('AC8: a 401 from the API signs the user out', async () => {
  localStorage.setItem('token', 'expired');
  stubApi({ 'GET /user_progress': () => ({ status: 401, body: { message: 'JWT expired' } }) });
  render(<App />);
  expect(await screen.findByRole('button', { name: /sign in/i })).toBeTruthy();
  expect(localStorage.getItem('token')).toBeNull();
});

test('AC9: empty library says so', async () => {
  localStorage.setItem('token', 'tok-1');
  stubApi({ 'GET /user_progress': () => ({ status: 200, body: [] }) });
  render(<App />);
  expect(await screen.findByText(/nothing tracked yet/i)).toBeTruthy();
});

test('review: a non-JSON error body still becomes an ApiError (401 signs out)', async () => {
  localStorage.setItem('token', 'tok-1');
  vi.stubGlobal('fetch', vi.fn(async () => new Response('<html>Unauthorized</html>', { status: 401, statusText: 'Unauthorized' })));
  render(<App />);
  expect(await screen.findByRole('button', { name: /sign in/i })).toBeTruthy();
});

test('review: signing up with a taken email shows a friendly message, not the DB error', async () => {
  stubApi({ 'POST /rpc/signup': () => ({ status: 409, body: { message: 'duplicate key value violates unique constraint "account_email_key"' } }) });
  render(<App />);
  await userEvent.click(screen.getByRole('button', { name: /create account/i }));
  await userEvent.type(screen.getByLabelText(/email/i), 'demo@manga.local');
  await userEvent.type(screen.getByLabelText(/password/i), 'a-long-password');
  await userEvent.click(screen.getByRole('button', { name: /sign up/i }));
  expect((await screen.findByRole('alert')).textContent).toBe('An account with this email already exists');
});

test('review: duplicate alt URLs both render', async () => {
  localStorage.setItem('token', 'tok-1');
  const dup = [{ ...rows[0], manga: { ...rows[0].manga, sites: [
    { url: 'https://op.example/', type: 'primary' }, { url: 'https://same.example/', type: 'alt' }, { url: 'https://same.example/', type: 'alt' }] } }];
  stubApi({ 'GET /user_progress': () => ({ status: 200, body: dup }) });
  render(<App />);
  const card = await screen.findByRole('article', { name: 'One Piece' });
  expect(within(card).getAllByRole('link', { name: /alt/i })).toHaveLength(2);
});
