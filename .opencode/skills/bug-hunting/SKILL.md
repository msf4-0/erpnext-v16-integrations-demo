---
name: bug-hunting
description: Static and dynamic bug-hunting playbook for the code-auditor agent. Use when asked to find bugs, audit for defects, investigate a crash/wrong behavior, review recent changes for regressions, or run tests to prove a bug. Covers logic/null/async/state/edge-case/contract smells plus repro-in-.audit workflow.
---

# Bug hunting

Goal: find real defects, prove them, and report them without ever editing source. Two modes — **static** (read) and **dynamic** (run) — always keep the distinction between **Confirmed** and **Suspected**.

## 1. Recon (5 minutes, do it first)
- Identify stack, entrypoints, and how it runs: `package.json` scripts, `Makefile`, `docker-compose.yml`, `README`, CI workflows.
- Identify the test/lint/typecheck/build commands. Run them if cheap; failures are leads.
- Build a mental map of modules and their contracts. `git log --oneline -20`, `git diff HEAD~5`, `git blame` on hot files to spot risky recent changes.

## 2. Static checklist

### Correctness
- Off-by-one in loops, ranges, slices, pagination (`<` vs `<=`, `len` vs `len-1`).
- Wrong operators: `=` vs `==`, `&&` vs `||`, `!` placement, `+` on strings, `%` sign behavior.
- Inverted conditions, unreachable branches, always-true/always-false guards, dead code.
- Wrong default values; defaults that mask missing config; env var typos.
- **Money**: float arithmetic, rounding modes, currency mixing. Should be integer/decimal.
- **Time**: timezone assumptions, DST, naive vs aware datetimes, off-by-one-day. **Units** mismatches (ms vs s, KB vs KiB).

### Failure handling
- Unchecked null/None/undefined; unchecked return values; ignored errors.
- Swallowed exceptions (`catch {}`, `except: pass`, empty promise `.catch`).
- Errors rendered to users that leak internals; errors never surfaced at all.
- Missing validation on the server (client-only validation).

### Async & concurrency
- Missing `await`; unhandled promise rejection; `.then` without `.catch`.
- Race conditions (read-modify-write without lock/transaction); TOCTOU.
- Stale closures capturing old state; `useEffect` dependency bugs.
- Double submit / double-click protection; idempotency keys on retries; non-idempotent retried writes.
- Ordering assumptions between concurrent requests.

### State & lifecycle
- Stale caches; cache invalidation missing; client/server state drift.
- Form state not reset after submit/close; optimistic UI without rollback.
- Memory leaks: listeners/intervals/subscriptions not removed; growing arrays.

### Edge cases to probe
- Empty string / empty list / all-whitespace; very large input; unicode & emoji; negative & zero numbers.
- Pagination boundaries (first page, last page, page beyond end).
- Concurrency (two users, two tabs); partial failures (one item fails mid-batch).
- Timeouts, offline, flaky network, slow responses; retries.

### Contracts & integration
- Frontend/backend field names, types, status codes, validation rules.
- API versioning mismatches; enum/status values that don't line up.
- Dead or half-implemented features; `TODO`/`FIXME`/`HACK`/`XXX`.
- Migrations that don't match the models; schema drift.

## 3. Dynamic checklist
- Run the existing test suite; record failures **and** coverage gaps (what critical paths have no tests).
- Run the linter and type checker; treat new warnings as leads.
- Start the app; exercise the flow. Compare behavior to README/spec/comments.
- For a suspected bug, **write a minimal failing repro in `.audit/repro/`**. Prefer the project's own test framework; otherwise a tiny script.
- Reload/re-query to confirm state actually persisted; check server logs alongside the UI.

## 4. Confirm vs suspect
- **Confirmed**: reproduced — failing test, stack trace, or concrete wrong response captured.
- **Likely from code**: clear from reading, not yet run.
- **Needs verification**: plausible but unproven.
Never upgrade confidence without evidence. If a test is blocked (no creds, service down), say so.

## 5. Grouping and reporting
- Collapse multiple symptoms with one root cause into a single bug with a list of symptoms.
- Output one bug block per root cause using the schema in the agent prompt (title, severity, type, env, steps, expected vs actual, evidence, root cause `file:line`, suggested fix, confidence, repro link).
- Save the report to `.audit/reports/<date>-<scope>.md`; summarize in chat; list what was not tested.

## 6. Hard boundaries
- Never edit source. Write only under `.audit/`.
- One command per bash call; no compound/network/deleting commands.
- No fuzzing at scale, no DoS, no bulk destructive actions.
