# ERPNext comp_demo — Setup Guide

> Authoritative stack architecture, ports, versions, and database durability:
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

> Built from the DeepSeek Harness session of 28 Oct 2026. Run commands from the repository root.
> The original Word document is committed alongside this file as [`SETUP-GUIDE.docx`](SETUP-GUIDE.docx).

## 1. What this stack is

A self-contained ERPNext v16 demo (Docker project `comp_demo`, site `frontend`) with:

- Barcode / QR item tracking (`barcode_shrdc`)
- E-invoicing (`eu_einvoice`)
- Drag-and-drop production planner (the `scheduler` service)
- Shopify ↔ ERPNext bridge (`shopify` app + Node-RED flow + ngrok webhooks)

See [`THIRD-PARTY.md`](THIRD-PARTY.md) for vendored-app licensing and redistribution status.

## 2. Prerequisites

- Windows with Docker Desktop, or Linux with Docker Engine and the Compose plugin.
- PowerShell for the full integration workflow (Windows PowerShell on Windows;
  PowerShell 7 / `pwsh` on Linux). The native Linux launchers use Bash, Python
  3, and curl without `pwsh`.
- Python 3.14 and the host ngrok binary (logged in) for the full integration workflow.
- A populated `.env` in the project folder (section 4). If it is missing, copy `.env.example` to `.env`.

## 3. Which command to type

Run from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

On Linux, use the native Bash launcher for a core ERPNext site:

```bash
cp .env.example .env       # if missing; edit the passwords
./up-linux.sh              # provision core ERPNext
./install-apps-linux.sh    # install barcode, Shopify, e-invoicing, item tracking
```

The app installer uses the repo's mounted app sources and installation helpers.
It does not configure Shopify credentials, Node-RED, ngrok, the planner,
Metabase, or demo data. The full integration workflow remains in
`up.ps1` / `setup.ps1`.

Notes:

- A one-line `setup.cmd` launcher is included so you don't have to remember the flags; the real work is in `setup.ps1` (and `up.ps1`).
- In PowerShell, plain `.\setup.ps1` also works if your execution policy allows scripts. A bare `setup.ps1` without `.\` does not run.
- The `-ExecutionPolicy Bypass` form works in `cmd.exe` as well and avoids "running scripts is disabled" errors.

Linux/macOS: run `./start.sh` (bash, Docker Compose v2). It pins the image
platform, seeds, starts, and runs `setup.ps1` through `pwsh` when PowerShell 7
is installed. `--no-pull`, `--no-wiring` and `--recreate` mirror the PowerShell
flags.
- `setup.ps1` exits 0 when all checks pass and 1 if anything is still broken.
### 3a. Fresh clone — one command

```powershell
git clone https://github.com/msf4-0/erpnext-v16-integrations-demo.git
cd erpnext-v16-integrations-demo
powershell -ExecutionPolicy Bypass -File .\start.ps1
```

`start.ps1` is the entry point for someone who has never seen this project:

1. creates `.env` from `.env.example` (no secrets required for the local demo)
2. `docker compose create` — pulls the bench image, or builds it once if the tag
   is not pullable
3. starts db + redis, waits for the database to be healthy
4. runs the one-shot `seed` service and waits for the ~5 min restore
5. starts bench / node-red / metabase / planner and waits for `/api/method/ping`
6. runs `setup.ps1 -NonInteractive -SkipTunnel` to mint the API tokens and start
   the background jobs, skipping Shopify and ngrok (both optional)

It is idempotent — run it again any time instead of remembering the order.
Timing on a warm machine: **~8 min** when the image is already present,
**25–40 min** on the first run because the 3 GB bench image is built locally.

**The image is the slow part.** `docker-compose.yml` defaults to a locally
built `comp_demo-bench:v16`. CI publishes `ghcr.io/msf4-0/comp-demo-bench:v16`,
and `start.ps1` now pulls that image automatically on a first run (it tags it as
`comp_demo-bench:v16`, so compose uses it and never builds).

If the pull fails, the package is still **private** and the script says so:

```
WARN  prebuilt image not pullable (package still private, or you are offline)
WARN    one-time fix: https://github.com/msf4-0?tab=packages -> comp-demo-bench
WARN                  -> Package settings -> Change visibility -> Public
```

That maintainer click is still the clean way to make GHCR public, but it is no
longer the only path: `pull-bench.ps1` / `start.sh` now fall back to the
**public GitHub Release bundle** - one ~1 GB asset, no account, no token,
checksum verified, then `docker load`. Only if both fail does the script build
locally (25-40 min). `-NoPull` skips both fetches; `-Pull` forces a fresh try.
See [`docs/DISTRIBUTION.md`](docs/DISTRIBUTION.md) section 5.

See [`docs/DISTRIBUTION.md`](docs/DISTRIBUTION.md) for the acceptance criteria,
the go-live checklist and the measured timings.


### 3a-bis. Manual equivalent (if you prefer explicit steps)

```powershell
copy .env.example .env
docker compose create
docker start comp_demo-db-1 comp_demo-redis-cache-1 comp_demo-redis-queue-1
docker start comp_demo-seed-1          # wait until it exits 0
docker start comp_demo-bench-1 comp_demo-node-red-1 comp_demo-metabase-1
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -NonInteractive -SkipTunnel
```

`docker compose up -d` hangs on some Docker Desktop hosts; `create` + `start` is
the measured workaround, which is why both scripts use it.

### 3b. What actually works after that command

Be precise about this before promising a colleague "everything works".

| Capability | After `docker compose up` | To make it work |
|---|---|---|
| ERPNext + generic manufacturing demo (15 items, 5 multi-level BOMs, company SHRDC) | ✅ works | – |
| Logins: `Administrator`/`admin`, `demo@compdemo.local`/`demo` | ✅ works | – |
| `barcode_shrdc` (scan field, Barcode Printing, both desk JS) | ✅ works | – |
| `item_tracking` (Shift+I scanner, tracked items) | ✅ works | – |
| Planner UI + `/api/health` | ✅ page loads | – |
| Planner schedule / work orders / job cards | ❌ **401** – `SCHEDULER_ERPNEXT_API_KEY/SECRET` are blank, and the seeded secret cannot be decrypted (the new site has a new `encryption_key`) | run `.\setup.ps1` once – it mints fresh planner credentials |
| Shopify ↔ ERPNext bridge | ❌ skipped (no store/token) | fill `SHOPIFY_*` in `.env`, then `.\setup.ps1` |
| ngrok tunnel + the 3 ERPNext webhooks | ❌ skipped (no tunnel) | install + `ngrok config add-authtoken`, then `.\setup.ps1` |
| Metabase + "ERPNext Monitoring" dashboard | ✅ works – the seeder restores the `metabase` schema alongside the site, including the admin, the `ERPNext` data source and the 4-card dashboard. It is embedded inside ERPNext at **http://localhost:8000/metabase** and linked from Manufacturing → Manufacturing Analytics. | log in at :3005 with `METABASE_ADMIN_EMAIL` / `METABASE_ADMIN_PASSWORD` from `.env` |
| E-invoicing (`eu_einvoice`) | ⚠️ installed, but EU EN 16931 only – a Malaysian SST invoice will not validate | add an EU VAT template, or install `my_invois` (see `docs/ARCHITECTURE.md`) |
| `my_invois` (LHDN / MyInvois) | ✅ **installed** (`my_invois 0.0.1`) — source is at `repos/my_invois`, bind-mounted into the bench container. Submit-only layer; no fixtures synced | use as-is, or extend it; see `docs/ARCHITECTURE.md` |

So: **core ERPNext, barcode, item tracking and the demo data are hands-off.**
The four integrations that need external credentials (planner API, Shopify,
ngrok, Metabase) need one more command each, and `.\setup.ps1` does the first
three in one go.

Nothing above is silent: `setup.ps1 -VerifyOnly` prints a per-feature health
report, and `up.ps1` exits non-zero when an advertised feature is missing.

## 4. Configuration (.env)

All secrets live in `.env` (git-ignored). The repo ships `.env.example` with `__FILL_ME__` placeholders; on a fresh clone `setup.ps1` creates `.env` from it and prompts for the missing Shopify credentials. See section 9 for exactly which keys go where.

## 5. What setup.ps1 does (10 steps)

1. **Preflight** — Docker engine, Python, compose file, project files.
2. **.env paths and secrets** — absolute paths self-heal to the current folder.
3. **Containers** — the full PowerShell workflow loads `.env` and `versions.env`; the native Linux launcher starts only `db`, Redis, and `bench`.
4. **Bench** — site present, log folder present, background scheduler and worker started (step 5b).
5. **ERPNext token** — validated, rotated if rejected.
6. **Shopify token** — 24 h Admin API token minted from client credentials.
7. **Node-RED** — `flows.json` rebuilt with live tokens; container restarted.
8. **Tunnel** — ngrok started, public URL read back.
9. **Webhooks** — Delivery Note, Stock Entry and Stock Reconciliation webhooks pointed at the tunnel and enabled.
10. **Verify** — HTTP checks locally and through the tunnel.

## 6. Standard workflow

For the first build or a deliberate full reprovision:

```powershell
powershell -ExecutionPolicy Bypass -File .\up.ps1
```

On Linux:

```bash
bash ./up-linux.sh
bash ./install-apps-linux.sh
```

The first command provisions core ERPNext; the second installs the custom apps.
Neither configures the optional integrations described below.

Every other session:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

On Linux, rerun `bash ./up-linux.sh` to start/reuse the core site, and
`bash ./install-apps-linux.sh` to ensure the custom apps are installed.

Expected end state for the full PowerShell workflow: ERPNext, Planner, and Node-RED are up, and the webhooks respond locally and through the tunnel. The Linux launcher verifies only the core ERPNext site.

## 6b. Your data: what survives what

The short version: **the database is durable, the seed snapshot is not your work.**

| Action | Site DB (`db_data`) | Site files (`bench_sites`) | Custom apps / bench code |
|---|---|---|---|
| `docker restart`, Docker Desktop restart, `start.ps1` | kept | kept | rebuilt from the image |
| `docker compose down` (no `-v`) | **kept** | kept | container layer gone, restored from image |
| `docker compose down -v`, `up.ps1 -Fresh`, `setup.ps1 -Full -Wipe` | **deleted** | deleted | rebuilt |
| Site recreated by `bench new-site --force` | **deleted** | kept | – |

Two things used to destroy work silently, and both are now blocked:

1. **`--force` site recreation.** If `bench new-site` failed, provisioning retried
   with `--force`, which drops the site database. It now refuses unless
   `ALLOW_SITE_RECREATE=1` is set (only `-Full -Wipe` does that) and prints the
   backup command instead.
2. **Restoring a stale snapshot.** When the volume is gone, the seeder restores
   `seed/frontend-database.sql.gz` — a snapshot from the day it was last
   committed. Everything newer (BOMs, items, work orders) disappears. That is
   the "I lost more this week than last week" pattern.

So before anything destructive:

```powershell
powershell -ExecutionPolicy Bypass -File .\backup.ps1            # -> backups\<timestamp>\
powershell -ExecutionPolicy Bypass -File .\backup.ps1 -RefreshSeed   # also update seed/ so clones get current data
powershell -ExecutionPolicy Bypass -File .\restore.ps1 -Backup 20261116-110434
```

`setup.ps1 -Full` and `up.ps1 -Fresh` call `backup.ps1` automatically and abort
if the backup fails. `start.ps1` refuses to seed over a missing volume when host
backups exist unless you confirm.

## 7. Known gotchas

- The database lives in the `db_data` named volume and survives container and Docker restarts. `docker compose -p comp_demo --env-file .env --env-file versions.env -f docker-compose.yml down -v` deletes it; see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
- On the original Windows Docker Desktop host, `docker compose up -d` hangs; the Windows launcher uses `create` + `start`. The Linux core launcher uses `docker compose up -d`.
- Shopify tokens expire after 24 h; `setup.ps1` mints a new one each run.
- The ngrok URL changes on each tunnel start unless `NGROK_PUBLIC_URL` is pinned. `setup.ps1` re-wires the webhooks for you.
- Do not run `down -v` or `-Wipe` without intending to destroy the site.

## 8. Result after the rebuild

`up.ps1` finished with exit code 0; `setup.ps1` then ran clean (exit 0, all checks passing, zero outstanding issues).

- Barcode / QR + item tracking: 2 item barcodes, a Barcode Printing doc, a barcode-validated Delivery Note, and a scan-flagged Stock Entry.
- E-invoicing: authenticated check against E Invoice Import returned 200, plus a demo e-invoice Sales Invoice.
- Planner: 12 work orders, 24 job cards, 4 workstations.
- Shopify: 42 items synced, 2 sales orders imported.

## 9. Shopify token flow and where to put the keys

Node-RED never uses a Postman key. It calls Shopify with a 24-hour Admin API token that the setup scripts mint from your app's client ID and secret, then bake into the flow.

### How the token is made and used

1. You supply `SHOPIFY_STORE`, `SHOPIFY_CLIENT_ID` and `SHOPIFY_CLIENT_SECRET` in `.env` (once).
2. `setup.ps1` (step 7 at runtime) tests the current `SHOPIFY_ACCESS_TOKEN` with a cheap authenticated call.
3. If the token is missing or expired, the script posts `grant_type=client_credentials` with the client ID and secret to `https://<store>/admin/oauth/access_token`.
4. Shopify returns a new `shpat_…` token valid for 24 hours. The script writes it back to `SHOPIFY_ACCESS_TOKEN` in `.env`.
5. `build-flows.py` rewrites every Shopify node in `source-flow.json` with the store, API version and token, and writes `flows.json`.
6. Node-RED restarts with the new flow and sends the token in the `X-Shopify-Access-Token` header on each Admin API call.
7. `up.ps1` does the same minting during a full build. If the client ID or secret is missing, the script keeps the existing token and warns.

### Where to put each key by hand

Edit one file: `.env`. Use a plain-text editor, one `NAME=value` per line, no quotes and no spaces around `=`.

The exact menu path to your Shopify app's client ID and secret depends on how the app was created. Look for "Client ID" and "Client secret" in the app's settings/credentials page (Shopify admin → Settings → Apps → Develop apps → your app).

### Manual steps

1. Open `.env` and fill `SHOPIFY_STORE`, `SHOPIFY_API_VERSION`, `SHOPIFY_CLIENT_ID` and `SHOPIFY_CLIENT_SECRET`. Save the file.
2. From the repository root, run `powershell -ExecutionPolicy Bypass -File .\setup.ps1`. It mints the token, rebuilds the flow and restarts Node-RED.
3. Check the output for `FIXED Shopify token minted: shpat_… valid 24h`, then run `setup.ps1 -VerifyOnly` for a read-only health report.

If you only have a ready-made `shpat_…` token and no client credentials, paste it into `SHOPIFY_ACCESS_TOKEN` and run `setup.ps1 -SkipShopify -ForceFlow`. That skips minting and rebuilds the flow with the token you pasted. A token pasted this way cannot renew itself, so Shopify calls will return 401 once it expires.

Never paste these values into the flow JSON or share them in chat. Re-run `setup.ps1` instead so every node gets the same token.

## 10. Testing each feature

Run `setup.ps1 -VerifyOnly` first. If it is clean, test each feature below. The seeded demo records came from the `up.ps1` build. Steps marked "not inspected" rely on standard ERPNext behaviour. Use new documents for tests, not the seeded ones; test data persists across Docker restarts in the `db_data` volume.

### Barcode scanning

The barcode app is `barcode_shrdc`. Its doctype is **Barcode Printing**; item barcodes live in the standard Item form (Barcodes table, child doctype Item Barcode). The demo created two item barcodes, `SHRDC-BRK-0001` and `SHRDC-KIT-0001`, plus four enabled Client Scripts.

- **Find the barcodes to scan.** Log in at http://localhost:8000 as `Administrator` / `admin`. Open Delivery Note `MAT-DN-2026-00001` (`/app/delivery-note/MAT-DN-2026-00001`) and note its item codes. Click an item to open the Item and read its Barcodes table (`SHRDC-BRK-0001`, `SHRDC-KIT-0001`).
- **Check barcode printing.** Open `/app/barcode-printing` and open `BP-2026-10-28-00001`. Confirm a barcode/QR image renders and print preview shows it. A broken-image icon or empty box is a failure.
- **Scan onto a new Delivery Note.** Open `/app/delivery-note/new`, choose customer *Demo Buyer SHRDC*, click the Scan Barcode field, type `SHRDC-BRK-0001`, press Enter. An item row is added with qty 1. Scanning the same code again increments qty to 2 (not a second row).
- **Negative test.** Type `XXX` in Scan Barcode and press Enter — expect an error and no row.
- **Hardware scanner.** Click the Scan Barcode field first, then scan; most USB scanners type + Enter. If nothing is added, the scanner may not send Enter.
- **Scan onto a Stock Entry.** Open `/app/stock-entry/new`, choose Material Receipt (or Material Transfer), set the target warehouse, scan `SHRDC-KIT-0001`, confirm a row. Compare with the seeded `MAT-STE-2026-00003`. Click Save to create a draft, but do not submit yet.
- *Not inspected:* the exact field label and what the four Client Scripts do.

### Item tracking

The check is that scanned documents change stock correctly (drafts never move stock; submits do).

1. **Record the starting stock** — Stock Balance report (`/app/query-report/Stock Balance`), warehouse *Finished Goods - SHRDC*.
2. **Prove a draft changes nothing** — scan onto a new Delivery Note (qty 1), Save but don't submit; Stock Balance is unchanged.
3. **Submit and check the ledger** — Submit, then Stock Ledger shows a Delivery Note row, actual qty −1, and balance one lower.
4. **Test incoming stock** — Material Receipt into *Stores - SHRDC*, qty 5, submit; ledger +5, balance +5.
5. **Test a transfer** — Material Transfer *Stores* → *Finished Goods*, qty 2, submit; two ledger rows (−2 / +2), company total unchanged.
6. **Test a reversal** — Cancel one of your test Delivery Notes; a reversing entry returns the balance.
7. **Check the webhook** — each submit fires a webhook to Node-RED; confirm a 200 POST at http://localhost:4040.

Pass criteria: drafts never move stock, every submit moves it by the scanned quantity, and a cancel reverses it.

### E-invoicing

The app is `eu_einvoice`. The build confirmed it is installed and that E Invoice Import answers an authenticated REST request with status 200, plus a demo Sales Invoice `ACC-SINV-2026-00001`.

1. **Check the demo Sales Invoice** at `/app/sales-invoice/ACC-SINV-2026-00001` — it has customer, items, taxes and totals.
2. **Confirm the import doctype loads** at `/app/e-invoice-import`.
3. **Import a sample e-invoice** — New, attach a valid XRechnung XML or ZUGFeRD PDF, Save; the record fills in supplier, number, dates, totals.
4. **Create the ERPNext document** from the import record and compare totals/tax/line items to the cent.
5. **Negative tests** — a plain PDF or broken XML yields a clear error and no document.
6. **Test an outgoing e-invoice** from `ACC-SINV-2026-00001` using an e-invoice export/print option; validate the generated file.

Quick REST check (reads the token from `.env` without printing it):

```powershell
$tok = (Select-String -Path .\.env -Pattern '^ERPNEXT_API_TOKEN=(.*)$').Matches.Groups[1].Value
$h = @{ Authorization = "token $tok" }
Invoke-RestMethod -Headers $h -Uri 'http://localhost:8000/api/resource/Barcode%20Printing'
Invoke-RestMethod -Headers $h -Uri 'http://localhost:8000/api/resource/E%20Invoice%20Import'
```

### Production planner

- http://localhost:3001/api/health → `"Server is running"`.
- http://localhost:3001/api/schedule → 12 work orders, 24 job cards, 4 workstations.
- http://localhost:3001 → drag a job card to a new date; the matching Work Order in `/app/work-order` shows the new dates.
- The Manufacturing workspace has a Production Planner shortcut. A demo Virtual Work Order `VWO-0001` was created with two sub work orders.

### Shopify → ERPNext, and webhooks

- Check the Item list for the synced Shopify products (42 items) and the Sales Order list for `SAL-ORD-2026-00001` and `-00002`.
- Place a test order in the Shopify store; it arrives as a new Sales Order after the scheduled order import runs.
- Open the ngrok inspector at http://localhost:4040, then submit a Delivery Note / Stock Entry / Stock Reconciliation; a 200 POST appears.
- Open Node-RED at http://localhost:1880 — the flow (47 nodes, 3 HTTP endpoints) is deployed with no red error markers.
- If Shopify calls 401, the 24 h token expired — run `setup.ps1`.

## 11. Security note

The session log contains secrets read during troubleshooting (database password, Shopify client secret, API tokens). Do not share the raw log or commit `.env`. Consider rotating the Shopify client secret if the log has been shared anywhere. This guide intentionally contains none of those values.

## Endpoints

| Service | URL | Notes |
|---|---|---|
| ERPNext | http://localhost:8000 | Login `Administrator` / `admin` (System Manager), or the demo user `demo@compdemo.local` / `demo` (non-admin `Demo User` role), site `frontend` |
| Production planner | http://localhost:3001 | Also linked in the Manufacturing workspace |
| Node-RED | http://localhost:1880 | 47-node flow, 3 webhook endpoints |
| ngrok API | http://localhost:4040 | Public URL changes on each tunnel start unless pinned |

## User roles & logins

`up.ps1` (step 8c) creates a non-admin demo role and login so the stack is ready
for real users, not just the build agent:

| Login | Password | Role | Scope |
|---|---|---|---|
| `Administrator` | `admin` | System Manager | build/maintenance only — do not hand to end users |
| `demo@compdemo.local` | `demo` | `Demo User` | read/write/create/submit on Items, Stock, Delivery Note, Sales Invoice/Order, Work Order, Job Card, Barcode Printing, E Invoice Import — read-only on masters (Company, Warehouse, Customer, Supplier) **and on the finance masters needed to save a document** (Account, Cost Center, Payment Terms Template, Tax Rule, Tax Category, Item Tax Template, Journal Entry, Payment Entry) |

The `Demo User` role has **no** System Manager or Setup access, so the account
cannot reach financial setup or destructive actions. Change the `demo` password
before any shared use.

## Scripts

| Script | When to use it | Time |
| `up.ps1` | Blank machine, or when deliberately provisioning from zero. | 25–35 min |
| `start.ps1` | **First command for a new machine.** Creates `.env`, creates/starts the containers in the right order, waits for the seed restore, then converges. Idempotent. | ~8 min warm, 25–40 min cold |
| `up.ps1` | Rebuild the bench from zero (provisioning path). Rarely needed now that the seed dump exists. | 25–35 min |
| `backup.ps1` | Snapshot the site to `backups/<timestamp>/` on the host. `-RefreshSeed` also updates the tracked dump. | ~15 s |
| `restore.ps1` | Restore a `backups/<timestamp>/` snapshot (takes a safety backup first). | ~1 min |
| `setup.ps1` | Every normal session. Converges the existing stack to match `.env` and verifies it. Safe to repeat. | 2–4 min |
| `setup.ps1 -VerifyOnly` | Read-only health report. | ~30 s |
| `setup.ps1 -Full` | Runs `up.ps1` first, then converges. | 25–35 min |
| `setup.ps1 -Full -Wipe` | Destructive: deletes volumes for a clean slate. | 25–35 min |
| `setup.ps1 -SkipShopify` / `-ForceFlow` | Skip minting a Shopify token / force a Node-RED flow rebuild. | – |
| `setup.ps1 -Planner` | After a clean converge, launch the `erpnext-planner` opencode agent to design custom doctypes. | interactive |

## Configuration variables (.env)

| Variable | Purpose | Status |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | Docker project name (`comp_demo`) | Set |
| `ENVIRONMENT` | `development` or `production`; production rejects demo-default passwords | `development` by default |
| `SITE_NAME`, `ERPNEXT_PORT` | Site `frontend`, port 8000 | Set |
| ERPNext image and release series | [`versions.env`](versions.env) | Authoritative pins |
| `DB_ROOT_PASSWORD`, `ERPNEXT_ADMIN_PASSWORD` | MariaDB root and initial ERPNext Administrator password | Development-only defaults; replace for production |
| `METABASE_PORT`, `METABASE_DB_USER`, `METABASE_DB_PASS`, `METABASE_ADMIN_EMAIL`, `METABASE_ADMIN_PASSWORD` | Metabase access and database/admin credentials | Defaults are development-only |
| `ERPNEXT_API_TOKEN` | Administrator key:secret for REST | Set; auto-rotated on 401 |
| `SHOPIFY_STORE`, `SHOPIFY_API_VERSION` | store host, API version | Set |
| `SHOPIFY_CLIENT_ID` / `SHOPIFY_CLIENT_SECRET` | Mint the Shopify Admin token | Set |
| `SHOPIFY_ACCESS_TOKEN` | `shpat_…` Admin token, valid 24 h | Re-minted by `setup.ps1` |
| `SCHEDULER_ERPNEXT_API_KEY` / `_SECRET` | Credentials for `planner@fix.local` | Set |
| `NODE_RED_PORT`, `SCHEDULER_PORT`, `NGROK_API_PORT` | 1880, 3001, 4040 | Set |
| `NODE_RED_SOURCE_FLOW`, `FLOWS_PATH` | Absolute paths to the Node-RED flow files | Self-healed on folder rename |
| `NGROK_AUTHTOKEN` | ngrok authtoken | Placeholder `__FILL_ME__`; the host ngrok binary uses its own saved config |
| `NGROK_PUBLIC_URL` | Pin a fixed public domain | Blank → random `*.ngrok-free.dev`, webhooks re-pointed automatically |

Image tags and the ERPNext series are maintained in [`versions.env`](versions.env).
The startup policy prints any demo-default password keys; with
`ENVIRONMENT=production`, the build and converge scripts stop before starting
containers until those passwords are changed.

## Where each key goes

| Key | Where it goes | Who fills it |
|---|---|---|
| `SHOPIFY_STORE` | `.env`, store host only, e.g. `yourstore.myshopify.com` (no `https://`) | You, once |
| `SHOPIFY_API_VERSION` | `.env`, currently `2026-04` | You, once |
| `SHOPIFY_CLIENT_ID` | `.env`, from your Shopify app's credentials page | You, once |
| `SHOPIFY_CLIENT_SECRET` | `.env`, from the same page | You, once |
| `SHOPIFY_ACCESS_TOKEN` | `.env`, `shpat_…` | `setup.ps1` / `up.ps1` (auto, every 24 h) |
| `ERPNEXT_API_TOKEN` | `.env`, key:secret | Scripts (auto-rotated on 401) |
| `SCHEDULER_ERPNEXT_API_KEY` / `_SECRET` | `.env` | Scripts (minted for `planner@fix.local`) |
| ngrok authtoken | Host ngrok config: `ngrok config add-authtoken <token>` once | You, once |

## Troubleshooting

| If this happens | Likely cause | What to check |
|---|---|---|
| No Scan Barcode field | Barcode Client Scripts not loaded/disabled | Hard refresh (Ctrl+F5), then `/app/client-script` — confirm the four barcode scripts are enabled |
| Desk reloads itself forever / "the site keeps restarting" | An **active** `app_include_js` 404s. Frappe reloads the desk when one of those assets fails, so the page loops instead of showing an error | `docker logs comp_demo-bench-1 \| grep asset-check`; then `curl -o NUL -w "%{http_code}`n" http://localhost:8000/assets/barcode_shrdc/js/scanner_barcode_patch.js` → must be `200`. Fix with `docker exec comp_demo-bench-1 bash -lc "cd /home/frappe/frappe-bench && export PATH=$(ls -d /home/frappe/.nvm/versions/node/*/bin | tail -1):$PATH && bench build --app barcode_shrdc"`, then restart the container |
| A valid barcode is not found | Barcode not in that item's Barcodes table | Open the Item and add the barcode |
| Barcode Printing image is broken | Image-rendering deps on the server | `setup.ps1 -VerifyOnly`, then `docker logs comp_demo-bench-1` |
| Everything is empty after `docker compose down -v` / `-Wipe` | volumes deleted on purpose | Run `up.ps1` |
| `AttributeError: is_ajax` in the browser | Masking error — a real exception fired inside `frappe.init()` before `frappe.local` was populated | Read the **first** traceback in `docker logs comp_demo-bench-1`, not the `is_ajax` one. Most common real cause: `ModuleNotFoundError: No module named '<app>'` |
| `ModuleNotFoundError` for an app that `bench list-apps` shows as installed | The running server's `sys.path` predates the app | `bench install-app` only writes a `.pth` that Python reads at startup — **restart the bench** (`docker restart comp_demo-bench-1`) after installing any app |

| If this happens | Likely cause | What to check |
|---|---|---|
| Submit fails with insufficient stock | Source warehouse holds less than scanned | Check Stock Balance, or do the Material Receipt first |
| Stock Ledger shows nothing | Filters too narrow, or document still a draft | Clear filters; confirm the document is Submitted |
| No webhook request appears | Tunnel down or webhooks not wired | Run `setup.ps1` (re-points the three webhooks) |

| If this happens | Likely cause | What to check |
|---|---|---|
| E Invoice Import is not found | App not installed | `docker exec comp_demo-bench-1 bash -lc "cd /home/frappe/frappe-bench && bench --site frontend list-apps"` → look for `eu_einvoice` |
| Import cannot read the file | Not a valid XRechnung / ZUGFeRD file | Try a different sample or validate the file first |
| REST call returns 401 | API token in `.env` is stale | Run `setup.ps1` to rotate it |
| Doctype/records are gone | Wrong site or deleted volume | Check Compose volumes and the configured site before reprovisioning |

## Repository layout & other scripts

```
docker-compose.yml        the services (planner build context ./scheduler)
start.ps1                 one-command first run: .env -> create -> seed -> start -> converge
backup.ps1 / restore.ps1  host-side DB snapshots; run before anything destructive
setup.cmd / setup.ps1     idempotent converge + verify of an existing stack (run this daily)
up.ps1                    full bring-up: compose -> bench -> apps -> seed -> Shopify -> planner -> flow -> tunnel -> verify
verify-all.ps1            41-check end-to-end suite (container + HTTP + browser DOM check)
refresh-shopify-token.ps1 re-mints the 24 h Shopify token and rebuilds the Node-RED flow
make-bundle.ps1           clean portable copy + zip + sha256, self-verified
sandbox/                  provisioning scripts, installers, seeders, probes, recipes, node-red flow builder
seed/                     demo DB dump (1.3 MB) + the seed service that restores it on a fresh volume
tests/                    verify-clean-clone.ps1 - disposable clone -> seed -> assert -> teardown
repos/                    app sources: barcode-shrdc-v16-fixed, shopify-shrdc-v16-fixed, eu_einvoice
scheduler/                the planner: server.js, prebuilt frontend/build, runtime-deps, ui-tests
.opencode/                opencode agents + skills (erpnext-planner, module-*, erpnext-test-runner)
docs/                     guides + MILESTONES.md (status, fixes, known gaps)
```

Status of every milestone, the fixes applied, and the honest not-ready list: [`docs/MILESTONES.md`](docs/MILESTONES.md).

## 12. Demos that need no external account

These work on a fresh clone with nothing filled in:

| Demo | Command | What you should see |
|---|---|---|
| Webhooks without ngrok | `docker compose up -d webhook-sink`, then submit a Delivery Note | payload in `curl localhost:8088/received` |
| Shopify order import | `./tools/shopify-replay/replay.sh` (or `replay.ps1`) | a Sales Order tagged `shopify_order_id 9001001` |
| MyInvois gating | open a submitted Sales Invoice -> **MyInvois -> Validate** | validation errors, no LHDN call, status unchanged/`Rejected` |
| Barcode + item tracking | Shift+I / Item form buttons | scan popup, tracked units, QR/barcode images |

The first two are demo tools, not a substitute for live credentials: the sink does
not verify Shopify HMACs, and replay exercises the mapping but not token minting
or rate limits.

## License

GPL-3.0-or-later - see [LICENSE](LICENSE). The apps import Frappe/ERPNext
(GPL-3.0), so GPL is the compatible choice.

- Contributing and the CI contract: [CONTRIBUTING.md](CONTRIBUTING.md)
- Reporting a vulnerability: [SECURITY.md](SECURITY.md)
- Image tags, digests, platforms and size budget: [docs/IMAGE-POLICY.md](docs/IMAGE-POLICY.md)
- Release criteria for "works for everyone": [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)
