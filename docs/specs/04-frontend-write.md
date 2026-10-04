# 04 — Frontend: update my progress and add titles

## Domain
The point of the app: after reading a chapter, bump the counter in one click. Also
change a title's status, mark whether it's worth reading, add a new title (or start
tracking one someone already added to the shared catalog), and stop tracking one.

**Done when:** every action below works against the real API from the browser and
has a passing component test.

## Technical
- Updates are `PATCH /user_progress?manga_id=eq.<id>` with only the changed field; RLS
  scopes them to the caller. The card updates optimistically and reverts with an
  error message if the API refuses, reverting only the fields that update changed.
  PATCHes are serialized per title so rapid +1 clicks reach the server in order.
- Add: `POST /manga` (title + optional primary URL; alt URLs are a later change), then
  `POST /user_progress`. A 409 on the title means it's already in the catalog: look
  it up (`title=eq.` is case-insensitive) and track that row instead of failing.
  The title field suggests existing catalog titles through a native `<datalist>`.
- Untrack: `DELETE /user_progress?manga_id=eq.<id>` after `confirm()`. The catalog row
  stays (other people may track it; the API can't delete catalog rows anyway).
- Chapter input: `type=number`, `min=0`, `step=0.1`, matching the DB rule.
- Editing a title's sites after creation is out of scope (creator-only in the API).

### Options considered
- *Refetch the whole list after each change*: simpler, but the +1 button should feel
  instant. Optimistic update + revert is ~10 lines.
- *A combobox library for the title picker*: `<datalist>` is native.

## Acceptance criteria (EARS) → `src/Library.write.test.tsx`
1. WHEN the user clicks +1, THE SYSTEM SHALL move to the next whole chapter
   (`floor(n) + 1`: 1194 → 1195, 703.7 → 704) immediately and PATCH that value for
   that manga only.
2. WHEN the user enters a chapter and saves, THE SYSTEM SHALL PATCH that value.
3. WHEN the user changes the status, THE SYSTEM SHALL PATCH `status`.
4. WHEN the user toggles worth-reading, THE SYSTEM SHALL cycle unset → yes → no →
   unset and PATCH `worth_reading`.
5. WHEN a PATCH fails, THE SYSTEM SHALL restore the previous value and show the
   API's error message.
6. WHEN the user adds a new title with a URL, THE SYSTEM SHALL create the catalog row
   with that URL as primary, track it as `reading`, and show it in the list.
   WHEN the title is already in the user's library, THE SYSTEM SHALL say so.
7. WHEN the title already exists in the catalog (409), THE SYSTEM SHALL track the
   existing row instead of showing an error.
8. WHEN the user confirms untracking, THE SYSTEM SHALL DELETE the progress row and
   remove the card; WHEN they cancel, nothing SHALL happen.
