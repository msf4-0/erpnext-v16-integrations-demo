# ERPNext Build

A **self-contained ERPNext v16 demo stack** that runs with one command and proves itself with
a 41-check test suite. Nothing outside this folder is read at build or run time.

It bundles four things that normally live apart:

| Piece | What it is |
|---|---|
| **ERPNext v16** | `frappe 16.53.0` + `erpnext 16.52.1` site `frontend`, MariaDB (tmpfs), Redis ×2 |
| **barcode_shrdc** | barcode / QR printing and scanning, incl. Code128 / Code39 / EAN13 + item tracking |
| **Shopify bridge** | `shopify` app (ERPNext → Shopify push with self-minting 24 h Admin API tokens) + a 47-node **Node-RED** flow exposed through **ngrok** webhooks |
| **Production planner** | separate Express + React app on :3001 with a drag-and-drop workstation matrix / calendar; Work Orders **and** Job Cards are draggable and persist to ERPNext |
| **EU e-invoicing** | `eu_einvoice`: EN 16931 → UN/CEFACT CII XML, XRECHNUNG auto-attach |

Docker compose project id: **`comp_demo`** (containers `comp_demo-bench-1`, `comp_demo-scheduler-1`, …).

## Quick start

```powershell
# 1. credentials (the repo ships examples only - no secrets are committed)
copy .env.example .env
copy sandbox\.env.ai-fix.example sandbox\.env.ai-fix
#    then fill: SHOPIFY_CLIENT_ID / SHOPIFY_CLIENT_SECRET / SHOPIFY_STORE, DB_ROOT_PASSWORD
#    (NGROK_AUTHTOKEN is optional: up.ps1 falls back to the host's ngrok.yml)

# 2. build + provision the whole stack (~25-35 min; the DB is tmpfs on purpose)
powershell -ExecutionPolicy Bypass -File .\up.ps1

# 3. prove it
powershell -ExecutionPolicy Bypass -File .\verify-all.ps1     # 41 checks, ~5 min
```

### Everyday: converge instead of rebuild

`up.ps1` builds from zero (25-35 min) and is the right call on a blank machine or after
`docker compose down`. For every other session — Docker restarted, the folder was renamed,
a 24 h Shopify token expired, the tunnel URL changed — run **`setup.ps1`**. It is idempotent
and takes ~2-4 min:

```powershell
.\setup.cmd                 # converge + verify (the everyday command)
.\setup.cmd -VerifyOnly     # read-only health report, ~30 s
.\setup.cmd -Full           # full rebuild via up.ps1, then converge
.\setup.cmd -ForceFlow      # rebuild + redeploy the Node-RED flow
```

It reconciles, in order: `.env` absolute paths (they break when the folder is renamed) →
containers → bench site + `server_script_enabled` → the ERPNext API token (rotates it via
`generate_keys()` when it 401s) → the 24 h Shopify token (only when the live one is dead) →
the Node-RED `flows.json` **and its bind mount** → the ngrok tunnel → the three ERPNext
Webhooks → a full verification. It exits non-zero if anything is still wrong.

> Why the mount matters: `flows.json` is bind-mounted from `FLOWS_PATH`. If that path is
> stale, Docker creates nothing, Node-RED keeps serving the flow it loaded at boot from
> memory, and the whole bridge silently disappears on the next restart. `setup.ps1` checks
> `/data/flows.json` inside the container, not just the HTTP port.

Endpoints once up:

| Service | URL |
|---|---|
| ERPNext | <http://localhost:8000> (`Administrator` / `admin`) |
| Production planner | <http://localhost:3001> |
| Node-RED | <http://localhost:1880> |
| ngrok agent API | <http://localhost:4040> |

## Layout

```
docker-compose.yml        the 6 services (planner build context ./scheduler)
setup.ps1 / setup.cmd     idempotent converge + verify of an existing stack (run this daily)
up.ps1                    11-step bring-up: compose -> bench init -> new-site -> apps -> seed -> Shopify -> planner -> flow -> tunnel -> verify
verify-all.ps1            41-check end-to-end suite (container + HTTP + real-browser DOM check)
refresh-shopify-token.ps1 re-mints the 24 h Shopify token and rebuilds the Node-RED flow
make-bundle.ps1           clean portable copy + zip + sha256, self-verified before it is declared good
sandbox/scripts/          provisioning, installers, seeders, probes, the frappe-level verify suite
sandbox/recipes/          per-app install recipes
sandbox/node-red/         flow builder + vendored source flow export (flows.json is generated)
repos/                    app sources: barcode-shrdc-v16-fixed, shopify-shrdc-v16-fixed, eu_einvoice
scheduler/                the planner: server.js, prebuilt frontend/build, runtime-deps, ui-tests
docs/                     MILESTONES.md (status + every fix + known gaps), WINDOWS-QUOTING.md
MANIFEST.md               exactly which files are needed, in three tiers
```

## Notes that save hours

- **The site DB is tmpfs by design.** Any `docker compose down` (or Docker engine restart) wipes the
  site; that is why the stack is *rebuildable* rather than backed up. `up.ps1` recreates and re-seeds
  everything in ~25–35 min.
- **Shopify tokens live 24 h.** The `shopify` app mints its own from the Dev Dashboard app
  credentials (`shopify/auth.py`); run `refresh-shopify-token.ps1` to refresh the Node-RED side.
- **Server Scripts must stay enabled** (`bench set-config -g server_script_enabled 1`, done by
  `ai-fix-postsetup.sh`) or a Work Order drag only moves its first operation.
- **`docker restart comp_demo-bench-1` kills `bench serve`.** Restart with
  `docker exec comp_demo-bench-1 bash -lc "cd /home/frappe/frappe-bench && setsid nohup bench serve --port 8000 >/tmp/bench-serve.log 2>&1 &"`.
- **Rebuilding the planner SPA** needs the toolchain that is *not* committed:
  `cd scheduler\frontend && npm ci && npm run build`. The committed `frontend/build` is what the
  Docker image copies.

Status of every milestone, the fixes applied, and the honest not-ready list: [`docs/MILESTONES.md`](docs/MILESTONES.md).
