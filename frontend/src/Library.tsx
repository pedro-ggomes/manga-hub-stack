import { useEffect, useState } from 'react';
import { api, ApiError, STATUSES, statusLabel, type Progress, type Status } from './api.ts';

const LIBRARY = '/user_progress?select=*,manga(id,title,sites)&order=updated_at.desc';

export function Library({ token, onSignOut }: { token: string; onSignOut: () => void }) {
  const [rows, setRows] = useState<Progress[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<Status | 'all'>('all');
  const [query, setQuery] = useState('');

  useEffect(() => {
    let live = true;
    api<Progress[]>(LIBRARY, { token })
      .then((r) => live && setRows(r))
      .catch((e) => {
        if (e instanceof ApiError && e.status === 401) onSignOut();
        else if (live) setError(e instanceof ApiError ? e.message : 'Could not reach the server');
      });
    return () => {
      live = false;
    };
  }, [token, onSignOut]);

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
            {shown.map((r) => <MangaCard key={r.manga_id} row={r} />)}
          </section>
        </>
      )}
    </main>
  );
}

function MangaCard({ row }: { row: Progress }) {
  const primary = row.manga.sites.find((s) => s.type === 'primary');
  const alts = row.manga.sites.filter((s) => s.type === 'alt');
  const titleId = `manga-${row.manga_id}`;
  return (
    <article className="card" aria-labelledby={titleId}>
      <h2 id={titleId}>{row.manga.title}</h2>
      <p className="meta">
        <span className={`status ${row.status}`}>{statusLabel(row.status)}</span>
        <span>Chapter {Number(row.last_chapter_read)}</span>
        {row.worth_reading && <span title="Worth reading">★</span>}
      </p>
      <p className="links">
        {primary && <a href={primary.url} target="_blank" rel="noopener noreferrer">Read</a>}
        {alts.map((s, i) => (
          <a key={i} href={s.url} target="_blank" rel="noopener noreferrer">Alt {i + 1}</a>
        ))}
      </p>
    </article>
  );
}
