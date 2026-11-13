# AGENTS.md — comp_demo (complete ERPNext demo workspace)

> Authoritative stack architecture, ports, versions, and database durability:
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

Self-contained ERPNext v16 demo **and** the workspace that drives it. One docker
project (`comp_demo`), one build command, everything included: barcode/QR item
tracking, e-invoicing, drag-and-drop production planning, Shopify ↔ ERPNext via
Node-RED, plus the **erpnext-planner** and module-* agents used to build it.

## Build & run (from the repository root)

```powershell
copy .env.example .env                        # if .env is missing (holds secrets — do not commit)
powershell -File .\up.ps1  # full build: stack + provision v16 + install apps + seed + verify
powershell -File .\up.ps1 -SkipProvision   # reuse an existing site (skip the long v16 provision)
powershell -File .\up.ps1 -SkipInstall     # reuse installed apps
powershell -File .\up.ps1 -SkipScheduler   # skip the planner image build (~6 min)
```

Full build ≈ 25–35 min. Status/down/logs (also usable directly):

```powershell
docker compose -p comp_demo --env-file .env --env-file versions.env -f docker-compose.yml ps
docker compose -p comp_demo --env-file .env --env-file versions.env -f docker-compose.yml down      # stop, keep volumes
docker compose -p comp_demo --env-file .env --env-file versions.env -f docker-compose.yml down -v   # WIPE the site and named volumes
```

## Endpoints

| Service | URL | Notes |
| --- | --- | --- |
| ERPNext (Desk + REST) | http://localhost:8000 | `Administrator` / development default `admin`, site `frontend` |
| Production planner | http://localhost:3001 | drag-and-drop scheduling; user `planner@ai-fix.local` |
| Node-RED (Shopify bridge) | http://localhost:1880 | flow: `sandbox/node-red/flows.json` |
| Metabase | http://localhost:3005 | analytics dashboards |
| ngrok API | http://localhost:4040 | host ngrok binary (no container) |

## Features in the build

- **Barcode / QR item tracking** — `barcode_shrdc` (v16-fixed, source in `repos/barcode-shrdc-v16-fixed`), `Barcode Printing` doctype; server-side rasterisation deps pre-installed.
- **E-invoicing** — `eu_einvoice` (alyf-de, version-16 branch).
- **Drag-and-drop production planning** — the `scheduler` service + `seed_planner_demo.py` demo data (Work Orders ↔ Job Cards).
- **Shopify ↔ ERPNext** — `shopify` app + Node-RED flow + ngrok webhooks; store `SHOPIFY_STORE` in `.env`.

## Agents (this workspace)

| Agent | Mode | Purpose |
| --- | --- | --- |
| `erpnext-planner` | primary | Question-first ERPNext consultant: runs the 10-phase interview (`question-bank.md`), then Spec + Impact Matrix, waits for "approved" before coding. |
| `erpnext-test-runner` | subagent | Builds/rebuilds/tears down the comp_demo stack for testing a change. |
| `module-developer` | primary | Authors new doctypes/features into an app repo under `repos/`, verified on comp_demo. |
| `module-installer` | primary | Provisions the comp_demo sandbox and installs named custom apps. |
| `module-fixer` | primary | Fixes already-installed modules in the running comp_demo bench. |

Skills live in `.opencode/skills/` (interview, doctype-builder, production-workflow, demo-data, test-sandbox, …). Sub-agents imported from `the external ERPNext AI Script workspace`; planner + test-runner from `the external SHRDC OpenCode ERP workspace`. After editing any agent/skill/config, **restart opencode**.

## Gotchas

- **`docker compose up -d` HANGS on this host.** `up.ps1` starts containers with `docker compose create` + `docker start`.
- **The DB lives in the `db_data` named volume** mounted at `/var/lib/mysql` and persists across container and Docker restarts. `docker compose -p comp_demo --env-file .env --env-file versions.env -f docker-compose.yml down -v` deletes it; see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
- Verification is **REST-based** (`/api/resource/...`), not UI-based. Never treat a returned UI action as proof of change.
- Never run destructive flows (`down -v`, cancel/delete/submit financial docs) without explicit confirmation.
- No `pwsh` on PATH; use `powershell.exe -NoProfile -ExecutionPolicy Bypass -File`.
