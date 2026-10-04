# How I use AI on this project

This repo is built with Claude Code as a pair programmer. I direct and approve; the
agent writes specs, tests and code, runs them, and reports back. This page explains the
rules it works under, so anyone reading the history knows how a change got here and how
much to trust it.

The rules come from two files the agent reads at the start of every session:

- my global `~/.claude/CLAUDE.md`, the same for every project
- this repo's [`CLAUDE.md`](../CLAUDE.md), which adds the stack, the core modules and
  the "never" list

## 1. One feature at a time

Work moves in small slices (see [`PLAN.md`](PLAN.md)). Each slice has one owner, one
branch and one PR, and should take days, not weeks. At most two things are in progress
per person. There are no sprints or story points; the next slice starts when the
previous one is merged.

## 2. The feature loop

Every non-trivial change goes through six steps, in order:

1. **Spec.** A file in `docs/specs/` with two parts. *Domain*: the problem and what
   done means. *Technical*: architecture, edge cases, security, data contracts. It also
   lists the options that were considered and why they lost. Acceptance criteria use
   [EARS](https://alistairmavin.com/ears/) notation:
   `WHEN <condition>, THE SYSTEM SHALL <observable behavior>`.
   If the spec is ambiguous, the agent stops and asks.
2. **Tests first.** Each acceptance criterion maps to a named test. The tests are run
   and must fail, for the right reason, before any implementation exists.
3. **Build** the smallest change that makes them pass.
4. **Eval gate.** `make test` runs the whole suite. Green moves on, red goes back.
   "Done" means the gate passed, not that the code was written.
5. **Risk review.** Did the change touch the core? Then I review it and approve the
   merge myself. Otherwise automated review plus a spot check is enough.
6. **Merge** and write a short summary, then pull the next slice.

## 3. TDD rules

- No production code without a failing test that asks for it.
- Bug fixes start with a test that reproduces the bug.
- Tests check behavior and contracts, not implementation details.
- Edges named in the spec get tests too: empty input, boundaries, malformed data,
  failure paths, and concurrency.
- Database tests run against real Postgres, never SQLite, because the constraints and
  locks being tested don't exist there.
- Any rule like "at most one X per Y" is enforced in the database (unique constraint or
  row lock) and proven with a test that sends real concurrent requests.
- Tests are fast, isolated and deterministic: no wall clock, no network, no ordering.
  External services are mocked at the boundary.

## 4. Core vs. periphery

Core is the code where a mistake is expensive or hard to undo. Here that means auth,
RLS policies, migrations that change existing data, and replication (Electric,
pg_mooncake). The full list is in `CLAUDE.md`.

- **Core changes never auto-merge.** A human reviews and approves, even under deadline
  pressure. In the plan these slices are marked ⛔.
- **Periphery** (UI, tooling, docs) needs the green gate plus automated review.
- When in doubt, it counts as core.

## 5. The "never" list

Hard limits the agent may not cross without asking:

1. Never edit a migration that has been merged to `main` after its human gate. Add a new
   migration instead. Migrations that only exist on a branch can still change.
   `make check-frozen` enforces this in CI.
2. Never commit `.env` or any secret.
3. Never grant table privileges to the `anon` role or expose the `auth` schema through
   the API.

The agent also needs approval before deleting files, adding dependencies or
integrations, pushing or merging, or anything outside the working tree. When one of
those actions is blocked, it stops and explains instead of looking for a way around.

## 6. Tools the agent uses

| Tool | What it's for |
|------|---------------|
| **Ponytail** (plugin, always on) | Pushes toward the smallest solution that works. Before writing code it asks: does this need to exist? Is it already here? Does the standard library, the platform or the database already do it? Deliberate shortcuts get a `ponytail:` comment naming the limit and the upgrade path. `/ponytail-debt` collects them. |
| **Brainstorming** | Done in the spec's *Options considered* section: each real alternative, and why it lost. |
| **`/code-review`** | Correctness review of the diff before every PR. |
| **`/ponytail-review`** | A second review that only looks for over-engineering: what can be deleted or replaced with something built in. |
| **Up-to-date docs** | Library versions and APIs are checked against live sources (npm, Docker Hub, GitHub releases, official docs) on the day of the work, not taken from model memory. Context7 does this when it's connected; otherwise the agent queries the registries directly. Versions checked are recorded in `PLAN.md`. |

## 7. Definition of done

A slice is done only when all of these hold:

- Its acceptance criteria exist as passing tests.
- `make test` is green locally and in CI.
- Core changes passed my review.
- Lint and type checks pass with no new warnings.
- No secrets, debug output, dead code, or `TODO`s without an issue.

## 8. Security defaults

- Secrets come from the environment and never appear in code, logs, prompts or commits.
- Every query is parameterized. Every endpoint is authorized, which here means RLS on
  every table the API can reach.
- Dependencies and images are pinned.
- Everything runs in Docker and keeps no local state a restart would lose.
- No secrets or personal data go to a model that isn't cleared for it. Embeddings in
  this project come from a local Ollama model for that reason.

## 9. Commits and PRs

- Conventional, imperative commit messages that say why, and reference the spec.
- Only green states get committed.
- Each PR description links the spec and says what changed, how it was tested, and
  whether it touched the core.
- Commits written with the agent carry a `Co-Authored-By: Claude` trailer, so the
  history shows which work was AI-assisted.

## 10. Daily diary

On request, the agent reads the day's commits and PRs and writes
`YYYY-MM-DD_<name>.md`: what was done, where AI helped and where it went wrong, which
rules or tools worked, and whether the core was touched and gated. It counts
experiments, not features, and records regressions honestly.

## Running it yourself

```bash
make up      # build and start Postgres (creates .env from .env.example)
make test    # the eval gate: migrations up/down/up + pgTAP suite
make help    # everything else
```
