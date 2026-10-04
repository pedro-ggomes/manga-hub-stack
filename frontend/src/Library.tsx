import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react';
import { api, ApiError, STATUSES, statusLabel, type Manga, type Progress, type Status } from './api.ts';

const WITH_MANGA = 'select=*,manga(id,title,sites)';
const LIBRARY = `/user_progress?${WITH_MANGA}&order=updated_at.desc`;
type Change = Partial<Pick<Progress, 'status' | 'last_chapter_read' | 'worth_reading'>>;

export function Library({ token, onSignOut }: { token: string; onSignOut: () => void }) {
  const [rows, setRows] = useState<Progress[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<Status | 'all'>('all');
  const [query, setQuery] = useState('');
  const inFlight = useRef(new Map<number, Promise<unknown>>());

  const fail = useCallback(
    (e: unknown) => {
      if (e instanceof ApiError && e.status === 401) onSignOut();
      else setError(e instanceof ApiError ? e.message : 'Could not reach the server');
    },
    [onSignOut],
  );

  useEffect(() => {
    let live = true;
    api<Progress[]>(LIBRARY, { token })
      .then((r) => live && setRows(r))
      .catch((e) => live && fail(e));
    return () => {
      live = false;
    };
  }, [token, fail]);

  const patchRow = (id: number, change: Change) =>
    setRows((rs) => (rs ?? []).map((r) => (r.manga_id === id ? { ...r, ...change } : r)));

  // Optimistic: show the change now; if the API refuses, put back only the fields this
  // update changed. PATCHes for one title are chained so rapid clicks land in order.
  function update(row: Progress, change: Change) {
    setError(null);
    const id = row.manga_id;
    const before = Object.fromEntries(Object.keys(change).map((k) => [k, row[k as keyof Change]])) as Change;
    patchRow(id, change);
    const send = () =>
      api(`/user_progress?manga_id=eq.${id}`, { method: 'PATCH', token, body: change }).catch((e) => {
        patchRow(id, before);
        fail(e);
      });
    inFlight.current.set(id, (inFlight.current.get(id) ?? Promise.resolve()).then(send));
  }

  async function untrack(row: Progress) {
    if (!confirm(`Stop tracking ${row.manga.title}?`)) return;
    setError(null);
    const index = (rows ?? []).findIndex((r) => r.manga_id === row.manga_id);
    setRows((rs) => (rs ?? []).filter((r) => r.manga_id !== row.manga_id));
    try {
      await api(`/user_progress?manga_id=eq.${row.manga_id}`, { method: 'DELETE', token });
    } catch (e) {
      setRows((rs) => [...(rs ?? []).slice(0, index), row, ...(rs ?? []).slice(index)]);
      fail(e);
    }
  }

  /** Creates the catalog row, or reuses it when the title already exists, then tracks it. */
  async function add(title: string, url: string): Promise<boolean> {
    setError(null);
    try {
      let manga: Manga | undefined;
      try {
        [manga] = await api<Manga[]>('/manga', {
          method: 'POST',
          token,
          body: { title, sites: url ? [{ url, type: 'primary' }] : [] },
          prefer: 'return=representation',
        });
      } catch (e) {
        if (!(e instanceof ApiError && e.status === 409)) throw e;
        [manga] = await api<Manga[]>(`/manga?select=id,title,sites&title=eq.${encodeURIComponent(title)}`, { token });
        if (!manga) throw e;
      }
      try {
        const [row] = await api<Progress[]>(`/user_progress?${WITH_MANGA}`, {
          method: 'POST',
          token,
          body: { manga_id: manga.id, status: 'reading' },
          prefer: 'return=representation',
        });
        setRows((rs) => [row, ...(rs ?? [])]);
        return true;
      } catch (e) {
        if (e instanceof ApiError && e.status === 409) {
          setError(`${manga.title} is already in your library`);
          return false;
        }
        throw e;
      }
    } catch (e) {
      fail(e);
      return false;
    }
  }

  const counts = Object.fromEntries(STATUSES.map((s) => [s, rows?.filter((r) => r.status === s).length ?? 0]));
  const shown = (rows ?? []).filter(
    (r) => (filter === 'all' || r.status === filter) && r.manga.title.toLowerCase().includes(query.toLowerCase()),
  );

  return (
    <main>
      <header>
        <h1>Manga Hub</h1>
        <button type="button" onClick={onSignOut}>Sign out</button>
      </header>
      {rows && <AddTitle token={token} onAdd={add} onError={fail} />}
      {error && <p role="alert">{error}</p>}
      {rows?.length === 0 && <p>Nothing tracked yet.</p>}
      {rows && rows.length > 0 && (
        <>
          <nav className="filters" aria-label="Filter by status">
            <button type="button" aria-pressed={filter === 'all'} onClick={() => setFilter('all')}>
              All ({rows.length})
            </button>
            {STATUSES.filter((s) => counts[s] > 0).map((s) => (
              <button key={s} type="button" aria-pressed={filter === s} onClick={() => setFilter(s)}>
                {statusLabel(s)} ({counts[s]})
              </button>
            ))}
          </nav>
          <input type="search" aria-label="Search titles" placeholder="Search titles" value={query} onChange={(e) => setQuery(e.target.value)} />
          <section className="grid">
            {shown.map((r) => (
              <MangaCard key={r.manga_id} row={r} onChange={(c) => update(r, c)} onUntrack={() => untrack(r)} />
            ))}
          </section>
        </>
      )}
    </main>
  );
}

const nextWorth = (w: boolean | null): boolean | null => (w === null ? true : w ? false : null);
const worthLabel = (w: boolean | null): string => (w === null ? 'not rated' : w ? 'yes' : 'no');

function MangaCard({ row, onChange, onUntrack }: { row: Progress; onChange: (c: Change) => void; onUntrack: () => void }) {
  const chapter = Number(row.last_chapter_read);
  const [draft, setDraft] = useState(String(chapter));
  useEffect(() => setDraft(String(chapter)), [chapter]);

  const primary = row.manga.sites.find((s) => s.type === 'primary');
  const alts = row.manga.sites.filter((s) => s.type === 'alt');
  const titleId = `manga-${row.manga_id}`;

  function saveChapter() {
    if (draft === '') return setDraft(String(chapter));
    const n = Number(draft);
    if (n !== chapter) onChange({ last_chapter_read: n });
  }

  return (
    <article className="card" aria-labelledby={titleId}>
      <h2 id={titleId}>{row.manga.title}</h2>
      <div className="controls">
        <label>
          Ch.
          <input
            type="number"
            aria-label="Last chapter read"
            min={0}
            step={0.1}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && saveChapter()}
            onBlur={saveChapter}
          />
        </label>
        <button type="button" onClick={() => onChange({ last_chapter_read: Math.floor(chapter) + 1 })}>+1</button>
        <button
          type="button"
          className={`worth ${worthLabel(row.worth_reading).replace(' ', '-')}`}
          aria-label={`Worth reading: ${worthLabel(row.worth_reading)}`}
          title={`Worth reading: ${worthLabel(row.worth_reading)}`}
          onClick={() => onChange({ worth_reading: nextWorth(row.worth_reading) })}
        >
          {row.worth_reading === null ? '☆' : row.worth_reading ? '★' : '✕'}
        </button>
      </div>
      <select aria-label="Status" value={row.status} onChange={(e) => onChange({ status: e.target.value as Status })}>
        {STATUSES.map((s) => <option key={s} value={s}>{statusLabel(s)}</option>)}
      </select>
      <p className="links">
        {primary && <a href={primary.url} target="_blank" rel="noopener noreferrer">Read</a>}
        {alts.map((s, i) => (
          <a key={i} href={s.url} target="_blank" rel="noopener noreferrer">Alt {i + 1}</a>
        ))}
        <button type="button" className="link untrack" onClick={onUntrack}>Untrack</button>
      </p>
    </article>
  );
}

function AddTitle({ token, onAdd, onError }: { token: string; onAdd: (title: string, url: string) => Promise<boolean>; onError: (e: unknown) => void }) {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [titles, setTitles] = useState<string[]>([]);

  useEffect(() => {
    if (!open) return;
    api<{ title: string }[]>('/manga?select=title&order=title', { token })
      .then((r) => setTitles(r.map((m) => m.title)))
      .catch(onError);
  }, [open, token, onError]);

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    setBusy(true);
    const added = await onAdd(String(form.get('title')).trim(), String(form.get('url') ?? '').trim());
    setBusy(false);
    if (added) setOpen(false);
  }

  if (!open) return <button type="button" className="add" onClick={() => setOpen(true)}>Add title</button>;
  return (
    <form className="add-form" onSubmit={submit}>
      <label>
        Title
        <input name="title" required maxLength={200} list="catalog-titles" autoComplete="off" />
      </label>
      <datalist id="catalog-titles">
        {titles.map((t) => <option key={t} value={t} />)}
      </datalist>
      <label>
        Primary URL
        <input name="url" type="url" pattern="https?://.+" placeholder="https://…" />
      </label>
      <button type="submit" disabled={busy}>Add</button>
      <button type="button" onClick={() => setOpen(false)}>Cancel</button>
    </form>
  );
}
