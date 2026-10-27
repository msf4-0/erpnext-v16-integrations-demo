---
name: bug-fixing
description: Root-cause bug-fixing workflow for the code-fixer agent. Use when fixing a defect or failing test: understand the root cause, write a failing repro first, make the smallest correct change, verify across edge cases, and never band-aid without saying so.
---

# Bug fixing

Fix the **root cause**, not the symptom. One finding at a time. Failing test first, passing test after.

## 1. Understand before editing
- Read the finding, then the function, its callers, and related files.
- Trace the data: where does the bad value come from, where does it go?
- Find the **root cause**, then ask: "where else does this exact pattern occur?" `grep` for it. List every location even if you only fix the reported one.
- If two symptoms share one cause, fix once and say so.

## 2. Reproduce
- Write a failing test (or `.audit/repro/` script, or browser repro) that fails **for the right reason**. Read the failure — if it fails for a different reason, your repro is wrong.
- If the project has no test setup, create the minimal one and tell the user.

## 3. Smallest correct change
- Change only what the root cause requires. No drive-by refactors, renames, or formatting churn.
- Match the project's existing style, naming, and patterns.
- No new dependency unless truly necessary — ask first.
- Prefer explicit handling over defensive blanket `try/except`.

## 4. Common root-cause patterns
- **Off-by-one / boundary**: fix the comparison, not the symptom. Test first/last/empty.
- **Null/None**: decide the correct behavior (default, skip, or clear error) — never silently swallow.
- **Empty collection**: guard before `max()/min()/sum()/len()` division; define the empty result.
- **State/caching**: fix invalidation at the source; clear every dependent cache.
- **Tenant/company leakage**: add the discriminator to **every** query/write, not just the read.
- **Async/race**: make the operation idempotent or transactional; avoid read-modify-write without a lock.
- **Rounding/money**: use decimals/integers, not floats.
- **Time/units**: normalize at the boundary; test timezone/DST.

## 5. Verify across edge cases
Run: the new test → full suite → linter → type checker. Then explicitly try: empty input, nulls, zero rows, huge/unicode/negative values, duplicates, concurrency (where relevant). For UI bugs, re-run the browser flow and confirm the fix and no regressions.

## 6. Honesty
- Never claim "fixed" without a passing test or a successful re-run.
- If you used a quick mitigation, label it and state the proper long-term fix.
- If a fix is partial/risky/unverified, say so.
- Never disable, skip, or weaken a test, lint rule, or security check to pass.
