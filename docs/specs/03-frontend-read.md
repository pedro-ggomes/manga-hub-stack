# 03 — Frontend: sign in and see my library

## Domain
A reader opens the app, signs in (or signs up), and sees their reading list: what
they're reading, where they left off, and a link to where they read it. They can
narrow it by status and by title.

**Done when:** a person can sign in with the demo account and browse their 18 titles
in the browser, and every behavior below has a passing component test.

## Technical
- Vite + React 19 + TypeScript, no router and no state library: two views (sign-in,
  library), chosen by whether a token exists.
- `src/api.ts`: one `fetch` wrapper. Base path `/api`, proxied by Vite to PostgREST.
  Errors become `ApiError(status, message)` using PostgREST's `message` field.
- Token in `localStorage`. ponytail: readable by any script on the page (XSS); move to
  an HttpOnly cookie behind a proxy before exposing the app beyond localhost.
- Library query: `GET /user_progress?select=*,manga(id,title,sites)&order=updated_at.desc`.
  Status filter and title search run client-side (one user's list is small).
- Any 401 from the API signs the user out (expired token).
- Tests: Vitest + Testing Library on jsdom; `fetch` is stubbed at the boundary.

### Options considered
- *TanStack Query*: caching and refetching we don't need yet for one list.
- *Server-side `ilike` search*: client-side is instant for a personal list; switch if
  lists grow into the thousands.
- *React Router*: two views don't need routes.

## Acceptance criteria (EARS) → `src/*.test.tsx`
1. WHEN there is no token, THE SYSTEM SHALL show the sign-in form.
2. WHEN the user signs in with valid credentials, THE SYSTEM SHALL store the token and
   show their library.
3. WHEN sign-in fails, THE SYSTEM SHALL show the API's error message and stay on the form.
4. WHEN the user chooses "Create account", THE SYSTEM SHALL call signup instead.
5. WHEN the library loads, THE SYSTEM SHALL list each title with status, last chapter
   read, and a link to its primary site (new tab, `noopener`), plus any alt links.
6. WHEN the user picks a status filter, THE SYSTEM SHALL show only titles with that
   status; the filter shows a count per status.
7. WHEN the user types in search, THE SYSTEM SHALL show only titles containing the
   text, ignoring case.
8. WHEN any API call returns 401, or the user signs out, THE SYSTEM SHALL clear the
   token and show the sign-in form.
9. WHEN the library is empty, THE SYSTEM SHALL say so instead of showing a blank page.
