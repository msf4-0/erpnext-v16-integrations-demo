# `setup/` — all operator commands in one place

Every bring-up, converge, backup and verification script for the comp_demo stack lives
here. Nothing in this folder is used at runtime by the application itself: ERPNext,
Node-RED, Metabase and the planner run from `docker-compose.yml`, `versions.env` and
`.env`, which stay at the repository root. These are the commands **you** run.

All scripts resolve the repository root as the parent of this folder, so they still
find `.env`, `.env.example`, `docker-compose.yml`, `versions.env`, `seed/`, `backups/`
and `sandbox/` exactly as before. Run them from anywhere; `cd` into the repo root if a
script prints relative paths.

## First run

| Platform | Command | What it does |
| --- | --- | --- |
| Windows (from repo root) | `.\setup.ps1` | **Forwarder at the repository root.** Identical to `.\setup\setup.ps1`, but the command you type never changes if this folder is reorganised again. Arguments pass straight through: `.\setup.ps1 -VerifyOnly`, `-Full`, `-Full -Wipe`. |
| Windows | `powershell -ExecutionPolicy Bypass -File .\setup\start.ps1` | Creates `.env` if missing, pulls (or builds) the bench image, creates/starts the containers in a safe order, waits for the seed restore, waits for ERPNext, then converges. |
| Windows (shortcut) | `.\setup\setup.cmd` | Same as running `setup.ps1` with execution-policy bypass — one-line launcher. |
| Linux / macOS | `bash ./setup/start.sh` | Bash twin of `start.ps1`: pull → seed → start → wiring (uses `pwsh` for the wiring step when available). |
| Linux (core only) | `bash ./setup/up-linux.sh` | Provisions the core ERPNext site with Docker Compose; no planner, Metabase, Node-RED, Shopify or ngrok. |
| Linux (apps) | `bash ./setup/install-apps-linux.sh` | Installs the bundled custom apps into an already-provisioned site. |

## Daily / repeatable

| Script | Purpose |
| --- | --- |
| `setup.ps1` | **The converge step.** Makes an existing or half-broken stack match `.env`, then verifies it. Idempotent — run it every session. Mints ERPNext tokens, rotates stale secrets, rebuilds the Node-RED flow, re-points webhooks. |
| `setup.ps1 -VerifyOnly` | Read-only health report (no changes). ~30 s. |
| `verify-all.ps1` | The 41-check end-to-end suite (M1–M10: stack, tunnel, Shopify, planner, barcode, e-invoicing). |
| `scheduler-up.ps1` | Planner-only bring-up: builds the `scheduler` service, mints the planner token, seeds manufacturing data, verifies the round-trip. |
| `metabase-seed.ps1` | One-time, idempotent Metabase setup: admin account + ERPNext DB data source. |
| `refresh-shopify-token.ps1` | Mints a fresh 24 h Shopify Admin token and pushes it into `.env` and every Node-RED node. Run it when Shopify calls start returning 401. |

## Rebuild / destructive

| Script | Purpose |
| --- | --- |
| `up.ps1` | Full bring-up from zero on a blank machine: compose → bench → apps → seed → Shopify → planner → flow → tunnel → verify (25–35 min). Rarely needed now that the seed dump exists. |
| `setup.ps1 -Full` | Runs `up.ps1`, then converges. |
| `setup.ps1 -Full -Wipe` | Same, after deleting volumes. Destroys data. |
| `pull-bench.ps1` | Makes the prebuilt bench image available (GHCR → release tarball → local build). Called automatically by `start.ps1` / `up.ps1` / `setup.ps1 -Full`. |

## Data safety

| Script | Purpose |
| --- | --- |
| `backup.ps1` | Snapshots the site to `backups/<timestamp>/` on the host. `-RefreshSeed` also updates the tracked dump. Run before anything destructive. |
| `restore.ps1 -Backup <name>` | Restores a snapshot into the running stack (takes a safety backup first). Pauses the scheduler/worker during the restore. |

## Packaging

| Script | Purpose |
| --- | --- |
| `make-bundle.ps1` | Produces a clean, portable copy + zip + SHA256 of the project, and runs `verify-all.ps1` from the copy so the bundle proves itself. |

## Notes

- `.env`, `.env.example`, `docker-compose.yml` and `versions.env` deliberately stayed at
  the repository root: Docker Compose, CI and the seed restore read them from there.
- Commands in older docs/notes that say `.\up.ps1` now mean `.\setup\up.ps1`; the
  repository README and the documents under `docs/` have been updated.
- Nothing here was pushed. The move is a local `git mv` plus path fixes.
