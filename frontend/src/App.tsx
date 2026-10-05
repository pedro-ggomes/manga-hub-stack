import { useCallback, useState, type FormEvent } from 'react';
import { api, ApiError } from './api.ts';
import { Library } from './Library.tsx';

// ponytail: token in localStorage is readable by any script on the page (XSS);
// move it to an HttpOnly cookie behind a proxy before exposing the app beyond localhost.
export default function App() {
  const [token, setToken] = useState(() => localStorage.getItem('token'));
  const signIn = useCallback((t: string) => {
    localStorage.setItem('token', t);
    setToken(t);
  }, []);
  const signOut = useCallback(() => {
    localStorage.removeItem('token');
    setToken(null);
  }, []);
  return token ? <Library token={token} onSignOut={signOut} /> : <SignIn onToken={signIn} />;
}

function SignIn({ onToken }: { onToken: (token: string) => void }) {
  const [mode, setMode] = useState<'login' | 'signup'>('login');
  const [error, setError] = useState<string | null>(null);

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    try {
      const { token } = await api<{ token: string }>(`/rpc/${mode}`, {
        method: 'POST',
        body: { email: form.get('email'), password: form.get('password') },
      });
      onToken(token);
    } catch (err) {
      if (err instanceof ApiError && err.status === 409) setError('An account with this email already exists');
      else setError(err instanceof ApiError ? err.message : 'Could not reach the server');
    }
  }

  return (
    <main className="signin">
      <h1>Manga Hub</h1>
      <form onSubmit={submit}>
        <label>
          Email
          <input name="email" type="email" required autoComplete="email" />
        </label>
        <label>
          Password
          <input
            name="password"
            type="password"
            required
            minLength={mode === 'signup' ? 12 : undefined}
            autoComplete={mode === 'signup' ? 'new-password' : 'current-password'}
          />
        </label>
        {error && <p role="alert">{error}</p>}
        <button type="submit">{mode === 'login' ? 'Sign in' : 'Sign up'}</button>
      </form>
      <button
        type="button"
        className="link"
        onClick={() => {
          setMode(mode === 'login' ? 'signup' : 'login');
          setError(null);
        }}
      >
        {mode === 'login' ? 'Create account' : 'I already have an account'}
      </button>
    </main>
  );
}
