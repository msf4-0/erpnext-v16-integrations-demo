# What you need to run comp_erpdemo

Everything lives in **one folder**: `F:\ERPNEXT\erpnext-build` Ã¢â‚¬â€ **36.4 MB, 1 514 files**.
No file outside it is read at build or run time (two deliberate fallbacks in `up.ps1` /
`scheduler-up.ps1` point at `F:\ERPNEXT\ERPNEXT-AI-FIX\sandbox` and are used **only** if
`comp_erpdemo\sandbox` is missing).
> **Naming:** the project folder is `comp_erpdemo`, but the **Docker project and the
> containers keep the original `comp_demo` id** (`comp_demo-bench-1`,
> `comp_demo-scheduler:latest`, `-p comp_demo`). They were not renamed on purpose: a new
> compose project recreates the containers, and because the site DB is tmpfs that means a
> full ~25-35 min rebuild. Rename them on your next rebuild â€” change `name:` /
> `COMPOSE_PROJECT_NAME`, `$Project` in `up.ps1` / `scheduler-up.ps1` / `verify-all.ps1`,
> and the `image:` / container references.

One command:

```powershell
powershell -ExecutionPolicy Bypass -File F:\ERPNEXT\erpnext-build\up.ps1     # full rebuild, ~25-35 min
powershell -ExecutionPolicy Bypass -File F:\ERPNEXT\erpnext-build\verify-all.ps1   # 41 checks, ~5 min
```

---

## Tier A Ã¢â‚¬â€ to just *start* the stack that already exists (3 files)

| File | Why |
|---|---|
| `docker-compose.yml` | the 6 services; planner build context is `./scheduler` |
| `.env` | ports, site name, DB root password, Shopify store + client credentials, planner port |
| `sandbox\.env.ai-fix` | planner integration user's API key/secret (+ Shopify token for the planner script) |

Plus the Docker images, which are not files in the folder:

- pulled: `frappe/bench:latest`, `mariadb:11.8`, `redis:6.2-alpine`, `nodered/node-red:latest`
- built here: `comp_demo-scheduler:latest` (from `./scheduler`, ~65 s, `COPY`-only)

```powershell
docker-compose -p comp_demo --env-file .env -f docker-compose.yml create
docker start comp_demo-db-1 comp_demo-redis-cache-1 comp_demo-redis-queue-1 comp_demo-bench-1 comp_demo-node-red-1 comp_demo-scheduler-1
```

**The site database is tmpfs on purpose**, so "just start it" only works while the
containers were never stopped. After a stop/restart the site is empty and you need Tier B.

---

## Tier B Ã¢â‚¬â€ to *rebuild* from zero (the real minimum)

Staged into the containers by `up.ps1`; nothing here is optional.

| Path | Files | Size | Role |
|---|---|---|---|
| `up.ps1` | 1 | 31 KB | 11-step bring-up (compose Ã¢â€ â€™ bench init Ã¢â€ â€™ new-site Ã¢â€ â€™ apps Ã¢â€ â€™ seed Ã¢â€ â€™ Shopify Ã¢â€ â€™ planner Ã¢â€ â€™ flow Ã¢â€ â€™ tunnel Ã¢â€ â€™ verify) |
| `scheduler-up.ps1` | 1 | 15 KB | planner-only bring-up (token, demo WOs, desk shortcut, health) |
| `sandbox\scripts\` | 198 | 0.6 MB | `provision-base.sh`, `install-app.sh`, `ai-fix-install.sh`, `ai-fix-postsetup.sh`, the seeders (`seed-demo-masters.py`, `seed-vwo-doctype.py`, `seed_planner_demo.py`), token helpers, probes |
| `sandbox\recipes\` | 9 | <0.1 MB | per-app install recipes (`barcode_shrdc`, `shopify`, `eu_einvoice`, Ã¢â‚¬Â¦) |
| `sandbox\node-red\` | 3 | 0.1 MB | `build-flows.py`, built `flows.json`, vendored `source-flow.json` |
| `repos\barcode-shrdc-v16-fixed\` | 52 | 0.5 MB | `barcode_shrdc` app (scan/fix fork) |
| `repos\shopify-shrdc-v16-fixed\` | 53 | 0.8 MB | `shopify` app incl. `shopify/auth.py` (24 h token minting) |
| `repos\eu_einvoice\` | 120 | 8.0 MB | e-invoicing app |
| `scheduler\` | 1 008 | 23.8 MB | the planner: `server.js`, `Dockerfile`, `package.json`, `runtime-deps\node_modules` (847 files, 4.6 MB Ã¢â‚¬â€ pre-installed, never `npm ci` in the image), `frontend\` source + **prebuilt `frontend\build`** (7 files, 4.7 MB) |
| `sandbox\.env.ai-fix` | 1 | 3 KB | planner creds |

`up.ps1` also needs the vendored `.env` (Tier A) Ã¢â‚¬â€ it reads ports, site name and the
Shopify client id/secret from it.

---

## Tier C Ã¢â‚¬â€ to verify / operate (not needed to run the demo)

| Path | Files | Role |
|---|---|---|
| `verify-all.ps1` | 1 | the 41-check end-to-end suite |
| `sandbox\scripts\verify-milestones.py` | (in B) | frappe-level half of that suite |
| `sandbox\scripts\probe-*.py`, `jc-shift.py`, `fix-*.py`, `shopify-token.py` | (in B) | read-only snapshots, drag diagnostics, demo-data repair, token status/refresh |
| `refresh-shopify-token.ps1` | 1 | re-mints the 24 h Shopify token and rebuilds the Node-RED flow (run daily-ish) |
| `scheduler\ui-tests\` | 8 + `node_modules\playwright-core` | real-Chrome checks (`ui-cards.mjs` read-only; `ui-drag-matrix.mjs`, `ui-drag-calendar.mjs` perform a drag) |
| `docs\MILESTONES.md` | 1 | status, every fix, the not-ready list |
| `docs\WINDOWS-QUOTING.md` | 1 | how to quote commands on this host |
| `.opencode\` | 38 | the agent presets/skills used to drive builds |

---

## Not needed (generated / caches Ã¢â‚¬â€ excluded from the portable bundle)

| Excluded | Why |
|---|---|
| `scheduler\frontend\node_modules\` (~300 MB) | only required to **recompile the SPA** (`cd scheduler\frontend && npm ci && npm run build`); the built `frontend\build` is in the bundle and is what the image copies |
| `__pycache__\`, `*.pyc` | regenerated |
| `rebuild-*.log`, `up-run*.log`, `up-rerun*.log` | build logs from this session (kept out; `verify-all-final.log` is kept as evidence) |
| site DB | **tmpfs by design** Ã¢â‚¬â€ lives in RAM inside `comp_demo-db-1`, wiped by any stop. That is why the demo is rebuildable rather than backed up |

---

## Host prerequisites (not project files)

- **Docker Desktop** (Linux engine) and `docker-compose.exe`
- **ngrok** binary + authtoken (read from the host's `ngrok.yml` if `.env` has none)
- **Node/npm** Ã¢â‚¬â€ only to rebuild the planner frontend
- **Python** Ã¢â‚¬â€ only for the Node-RED flow builder (`build-flows.py`)
- Ports free: 8000 (ERPNext), 3001 (planner), 1880 (Node-RED), 4040 (ngrok API)

---

## Secrets in this folder

`.env` and `sandbox\.env.ai-fix` hold the real values: DB root password, Shopify
**client id/secret** and access token, ERPNext API token, planner API key/secret. Treat
the folder as sensitive; rotate the Shopify client secret if you hand the bundle to
someone else.

---

## Portable copy

A clean, verified copy is produced by `make-bundle.ps1` (in this folder) into
`F:\erpnext-build-dist\`:

| Artefact | Contents |
|---|---|
| `F:\erpnext-build-dist\comp_erpdemo\` | the whole project minus the exclusions above |
| `F:\erpnext-build-dist\comp_erpdemo-<date>.zip` | the same tree as one archive + `SHA256.txt` |

**Share-safe variant** - `F:\comp_erpdemo-share\comp_erpdemo-share-<date>.zip` (7.9 MB) is the
same tree with **every credential replaced by `__FILL_ME__`**: `.env`, `sandbox\.env.ai-fix`,
the built `sandbox\node-red\flows.json` (which bakes in the ERPNext + Shopify tokens) and
`up.ps1` (which carried the ngrok authtoken). It ships a `SETUP-SECRETS.md` listing what the
recipient must fill in, and a leak scan over every text file confirms no live value survived.
This is the archive that was sent to Han on WhatsApp.

Both are verified before being declared good: `docker-compose config` resolves inside
the copy, and `verify-all.ps1` is run **from the copy** (41/41).
