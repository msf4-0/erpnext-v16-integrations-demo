---
name: git-safety
description: Git discipline for the code-fixer agent. Use before making changes and when committing fixes. Covers the dirty-tree check, fix/ branch naming, one commit per bug, protected branches, and the no-push/no-rewrite rules.
---

# Git safety (for code-fixer)

## Before the first change
1. `git status` — if the working tree is **dirty** (uncommitted changes), **stop and ask** the user. Do not stash, commit, or discard their work.
2. Note the current branch. If it is `main`, `master`, or `develop`, create a fix branch first.
3. If tests already fail, record the baseline (`<pass>/<fail>` + failing test names) before touching code.

## Branching
- Branch: **`fix/<short-description>`** (kebab-case, descriptive), e.g. `fix/verify-empty-filter`, `fix/bulk-upload-nan`.
- Create: `git checkout -b fix/<slug>` or `git switch -c fix/<slug>`.
- Never commit on `main`/`master`/`develop`. Switching to them is denied.

## Commits
- **One small commit per bug.** Message format:
  `fix(<area>): <what changed> [<FINDING-ID>]`
  Example: `fix(verify-data): guard empty filter statistics [BUG-002]`
- Include the finding ID; the body may note root cause and test added.
- Don't bundle unrelated changes into one commit. Don't reformat untouched files.

## Never
- `git push` (any form), force-push, `reset --hard`, `rebase`, `--amend`, `filter-branch`, `git config`, or history rewrites. These are **denied**.
- Commit directly to protected branches.
- Commit secrets, `.env`, credentials, or lockfile churn unrelated to the fix.
- `git branch -d/-D/-m` (delete/rename) — denied.

## After each fix
- Report: branch name, commit hash, and the finding-ID mapping.
- Tell the user to review the branch and to run `code-auditor`'s `/verify-fix <ID>` (independent check). **Do not push or merge** — the user does that.
