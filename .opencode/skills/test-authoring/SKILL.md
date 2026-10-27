---
name: test-authoring
description: Writing the failing test/repro first for the code-fixer agent. Use when adding a regression test or a repro script, detecting the project's test framework, or when no test setup exists. Covers red→green, edge cases, and never weakening tests.
---

# Test authoring

A fix is not done until a test proves it. Write the test **first**, watch it fail for the right reason, fix, then watch it pass.

## Detect the framework (don't assume)
Read `package.json` scripts, `pyproject.toml` / `pytest.ini` / `tox.ini`, `Makefile`, CI config, and existing `test*/`, `tests/`, `spec/` folders. Use whatever the project already uses (pytest, unittest, vitest, jest, go test, cargo test…). If none exists, create the **minimal** setup and tell the user.

## Red → green
1. Write the smallest test that reproduces the bug; assert the **correct** expected behavior.
2. Run it; confirm it fails for the bug's reason (read the actual failure).
3. Fix the code.
4. Run it; confirm green. Run the full suite to catch regressions.

## Cover the edges the bug implies
Empty input, null/None/undefined, zero rows, single row, huge/pagination boundary, unicode, negative, duplicate, ordering, timezone/units, partial failure. Prefer a **table/parametrized** test for boundaries.

## Repro when there's no test harness
Put a standalone repro in `.audit/repro/<name>.<ext>` that prints/asserts the failure. Optionally wire it to the real test runner later. Repro scripts are evidence — the fixer must not delete them.

## Rules
- **Never** disable, skip (`xfail`, `.skip`, `@Ignore`), weaken, or delete a test/lint/security check to make something pass.
- Assert on behavior/outcome, not on implementation details.
- Don't assert on unstable values (timestamps, random ids) without normalizing.
- Record the **baseline** first if tests were already failing, so you can prove you didn't add failures.
- For UI bugs, the repro is a repeatable browser flow; capture screenshot/console/network evidence.
