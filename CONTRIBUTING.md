# Contributing to comp_demo

This repository is a self-contained ERPNext v16 demo. The point is that **a
clean clone runs with one command on a machine that has never seen it** — keep
that true in every change.

## Before you open a PR

```powershell
# 1. From a clean clone, the demo must come up
powershell -ExecutionPolicy Bypass -File .\start.ps1 -NoWiring

# 2. Health must be clean for the features you touched
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -VerifyOnly

# 3. The working tree must be clean (CI fails on a dirty checkout)
git status --short
```

`ci.yml` runs on every push to `main` and every PR:

| Job | What it enforces |
|---|---|
| `repository-hygiene` | clean checkout, every app under `repos/` has a non-empty `hooks.py`, no `F:\` / `C:\Users` paths in scripts, no retired `sandbox/up.ps1` |
| `validate` | `docker compose config`, every `*.ps1` parses, shellcheck (errors only), Python compiles, barcode templates are non-empty |
| `build-bench-image` | the bench image builds; on `main` it is pushed to GHCR |
| `smoke` | the pushed image imports `frappe, erpnext, barcode_shrdc, shopify, eu_einvoice, reportlab, qrcode, PIL, drafthorse, saxonche` |

## Suites that run outside `ci.yml`

```bash
# Nightly cold-start (Actions -> e2e -> Run workflow, or schedule at 03:17 UTC):
#   pull -> seed -> ping -> login -> seeded DocType -> planner health

# App tests, against a running site:
docker exec comp_demo-bench-1 bash -lc \
  "cd /home/frappe/frappe-bench && bench --site frontend set-config allow_tests true \
   && bench --site frontend run-tests --app my_invois"
```

The MyInvois suite proves the demo contract: with no credentials, submitting
never contacts LHDN and never reports success.

## Rules that are not negotiable

1. **Never commit only part of an app.** A `hooks.py` without its package, or a
   `.json` without its `.py`, creates a hollow clone. `repository-hygiene`
   exists because that happened.
2. **No machine-specific paths** (`F:\...`, `C:\Users\...`) in scripts,
   workflows, `.env.example` or shell scripts. Prose docs may mention a machine
   as an example.
3. **No secrets in the tree.** `.env` is git-ignored; only `.env.example` with
   `__FILL_ME__` placeholders is committed.
4. **A new feature is not done until `setup.ps1 -VerifyOnly` reports it**, or
   the README capability table says it needs credentials.
5. **Keep the slow path explicit.** Anything that can take minutes (images,
   seeds, builds) must print what it is doing and why.

## Commit style

```
<type>(<scope>): <imperative summary>

<why, and what was verified>
```

Types in use: `feat`, `fix`, `docs`, `ci`, `chore`. Scope examples: `dist`,
`setup`, `apps`, `seed`, `planner`, `shopify`.

## Where things live

| Path | Purpose |
|---|---|
| `start.ps1` / `start.sh` | newcomer entry point (pull → seed → start → wire) |
| `setup.ps1` | convergence + verification (10 steps, idempotent) |
| `up.ps1` | rebuild path, calls `pull-bench.ps1` before `compose create` |
| `docker-compose.yml` | the whole stack; `name: comp_demo` |
| `bake/bench.Dockerfile` | the 3 GB bench image |
| `repos/<app>` | app sources baked into (or installed from) the image |
| `seed/` | demo database dump and the one-shot seeder |
| `docs/DISTRIBUTION.md` | release criteria for shipping the demo |
| `docs/HANDOFF.md` | what was left unfinished and why |

## Reporting

Use the issue templates. For a distribution failure include:

- `docker version` and host OS/arch
- the image digest (`docker image inspect --format '{{index .RepoDigests 0}}'`)
- the exact step that failed and its last 30 lines
- whether `docker manifest inspect ghcr.io/msf4-0/comp-demo-bench:v16` works
  anonymously (this distinguishes a private-package problem from a real bug)

## License

Contributions are accepted under GPL-3.0-or-later (see `LICENSE`). The custom
apps import Frappe/ERPNext, which are GPL-3.0, so GPL is the compatible choice.
