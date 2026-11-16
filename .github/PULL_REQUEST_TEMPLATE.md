# Pull request

## What this changes

<!-- one paragraph; link the issue with "Closes #N" -->

## Verified on a clean clone

- [ ] `start.ps1 -NoWiring` reaches `/api/method/ping` 200
- [ ] `setup.ps1 -VerifyOnly` shows no new failures
- [ ] `git status --short` is clean (CI fails on a dirty checkout)
- [ ] If the bench image changed: `docker compose build bench` succeeds, or the
      image was rebuilt by CI and pulled back

## Distribution impact

- [ ] Does not change the first-run path
- [ ] Changes the first-run path — timing before/after: `___ min -> ___ min`

## Checks

- [ ] No `F:\`, `C:\Users` or other machine-specific paths in scripts/workflows
- [ ] No secrets, tokens or `.env` committed
- [ ] Every app under `repos/` still has a non-empty `hooks.py`
- [ ] README capability table updated if a feature's status changed
