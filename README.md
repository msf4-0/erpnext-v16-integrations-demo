# ERPNext comp_demo — Setup Guide

> Built from the DeepSeek Harness session of 28 Oct 2026. Project folder: `F:\ERPNEXT\erpnextcomp_demo`.
> The original Word document is committed alongside this file as [`SETUP-GUIDE.docx`](SETUP-GUIDE.docx).

## 1. What this stack is

A self-contained ERPNext v16 demo (Docker project `comp_demo`, site `frontend`) with:

- Barcode / QR item tracking (`barcode_shrdc`)
- E-invoicing (`eu_einvoice`)
- Drag-and-drop production planner (the `scheduler` service)
- Shopify ↔ ERPNext bridge (`shopify` app + Node-RED flow + ngrok webhooks)

## 2. Prerequisites

- Windows with Docker Desktop (engine 29.x was used), Python 3.14, and the host ngrok binary — already logged in to ngrok.
- Use Windows PowerShell (`powershell.exe`).
- A populated `.env` in the project folder (section 4). If it is missing, copy `.env.example` to `.env`.

## 3. Which command to type

Run from the project folder:

```powershell
cd F:\ERPNEXT\erpnextcomp_demo
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Notes:

- A one-line `setup.cmd` launcher is included so you don't have to remember the flags; the real work is in `setup.ps1` (and `up.ps1`).
- In PowerShell, plain `.\setup.ps1` also works if your execution policy allows scripts. A bare `setup.ps1` without `.\` does not run.
- The `-ExecutionPolicy Bypass` form works in `cmd.exe` as well and avoids "running scripts is disabled" errors.
- `setup.ps1` exits 0 when all checks pass and 1 if anything is still broken.

## 4. Configuration (.env)

All secrets live in `.env` (git-ignored). The repo ships `.env.example` with `__FILL_ME__` placeholders; on a fresh clone `setup.ps1` creates `.env` from it and prompts for the missing Shopify credentials. See section 9 for exactly which keys go where.

## 5. What setup.ps1 does (10 steps)

1. **Preflight** — Docker engine, Python, compose file, project files.
2. **.env paths and secrets** — absolute paths self-heal to the current folder.
3. **Containers** — created and started with `docker compose create` + `docker start`.
4. **Bench** — site present, log folder present, background scheduler and worker started (step 5b).
5. **ERPNext token** — validated, rotated if rejected.
6. **Shopify token** — 24 h Admin API token minted from client credentials.
7. **Node-RED** — `flows.json` rebuilt with live tokens; container restarted.
8. **Tunnel** — ngrok started, public URL read back.
9. **Webhooks** — Delivery Note, Stock Entry and Stock Reconciliation webhooks pointed at the tunnel and enabled.
10. **Verify** — HTTP checks locally and through the tunnel.

## 6. Standard workflow

First build, or any time Docker Desktop has restarted:

```powershell
powershell -ExecutionPolicy Bypass -File .\up.ps1
```

Every other session:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Expected end state: `SETUP COMPLETE - all checks pass`, ERPNext / Planner / Node-RED up, and all three webhooks returning HTTP 200 both locally and through the tunnel.

## 7. Known gotchas

- The database lives in **tmpfs** (RAM) because DDL on a volume was extremely slow. Any Docker or container restart wipes the site database. The demo is *rebuildable, not persistent*; recovery is `up.ps1`.
- `docker compose up -d` hangs on this host. The scripts use `create` + `start` instead — do not replace this.
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

Edit one file: `F:\ERPNEXT\erpnextcomp_demo\.env`. Use a plain-text editor, one `NAME=value` per line, no quotes and no spaces around `=`.

The exact menu path to your Shopify app's client ID and secret depends on how the app was created. Look for "Client ID" and "Client secret" in the app's settings/credentials page (Shopify admin → Settings → Apps → Develop apps → your app).

### Manual steps

1. Open `.env` and fill `SHOPIFY_STORE`, `SHOPIFY_API_VERSION`, `SHOPIFY_CLIENT_ID` and `SHOPIFY_CLIENT_SECRET`. Save the file.
2. From `F:\ERPNEXT\erpnextcomp_demo`, run `powershell -ExecutionPolicy Bypass -File .\setup.ps1`. It mints the token, rebuilds the flow and restarts Node-RED.
3. Check the output for `FIXED Shopify token minted: shpat_… valid 24h`, then run `setup.ps1 -VerifyOnly` for a read-only health report.

If you only have a ready-made `shpat_…` token and no client credentials, paste it into `SHOPIFY_ACCESS_TOKEN` and run `setup.ps1 -SkipShopify -ForceFlow`. That skips minting and rebuilds the flow with the token you pasted. A token pasted this way cannot renew itself, so Shopify calls will return 401 once it expires.

Never paste these values into the flow JSON or share them in chat. Re-run `setup.ps1` instead so every node gets the same token.

## 10. Testing each feature

Run `setup.ps1 -VerifyOnly` first. If it is clean, test each feature below. The seeded demo records came from the `up.ps1` build. Steps marked "not inspected" rely on standard ERPNext behaviour. Use new documents for tests, not the seeded ones; the database is tmpfs, so test data disappears after a Docker restart.

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
| ERPNext | http://localhost:8000 | Login `Administrator` / `admin`, site `frontend` |
| Production planner | http://localhost:3001 | Also linked in the Manufacturing workspace |
| Node-RED | http://localhost:1880 | 47-node flow, 3 webhook endpoints |
| ngrok API | http://localhost:4040 | Public URL changes on each tunnel start unless pinned |

## Scripts

| Script | When to use it | Time |
|---|---|---|
| `up.ps1` | Blank machine, or after a Docker restart wiped the DB. Builds everything from zero. | 25–35 min |
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
| `SITE_NAME`, `ERPNEXT_PORT`, `ERPNEXT_VERSION` | Site `frontend`, port 8000, v16 | Set |
| `DB_ROOT_PASSWORD` | MariaDB root | Set |
| `ERPNEXT_API_TOKEN` | Administrator key:secret for REST | Set; auto-rotated on 401 |
| `SHOPIFY_STORE`, `SHOPIFY_API_VERSION` | store host, API version | Set |
| `SHOPIFY_CLIENT_ID` / `SHOPIFY_CLIENT_SECRET` | Mint the Shopify Admin token | Set |
| `SHOPIFY_ACCESS_TOKEN` | `shpat_…` Admin token, valid 24 h | Re-minted by `setup.ps1` |
| `SCHEDULER_ERPNEXT_API_KEY` / `_SECRET` | Credentials for `planner@ai-fix.local` | Set |
| `NODE_RED_PORT`, `SCHEDULER_PORT`, `NGROK_API_PORT` | 1880, 3001, 4040 | Set |
| `NODE_RED_SOURCE_FLOW`, `FLOWS_PATH` | Absolute paths to the Node-RED flow files | Self-healed on folder rename |
| `NGROK_AUTHTOKEN` | ngrok authtoken | Placeholder `__FILL_ME__`; the host ngrok binary uses its own saved config |
| `NGROK_PUBLIC_URL` | Pin a fixed public domain | Blank → random `*.ngrok-free.dev`, webhooks re-pointed automatically |

## Where each key goes

| Key | Where it goes | Who fills it |
|---|---|---|
| `SHOPIFY_STORE` | `.env`, store host only, e.g. `yourstore.myshopify.com` (no `https://`) | You, once |
| `SHOPIFY_API_VERSION` | `.env`, currently `2026-04` | You, once |
| `SHOPIFY_CLIENT_ID` | `.env`, from your Shopify app's credentials page | You, once |
| `SHOPIFY_CLIENT_SECRET` | `.env`, from the same page | You, once |
| `SHOPIFY_ACCESS_TOKEN` | `.env`, `shpat_…` | `setup.ps1` / `up.ps1` (auto, every 24 h) |
| `ERPNEXT_API_TOKEN` | `.env`, key:secret | Scripts (auto-rotated on 401) |
| `SCHEDULER_ERPNEXT_API_KEY` / `_SECRET` | `.env` | Scripts (minted for `planner@ai-fix.local`) |
| ngrok authtoken | Host ngrok config: `ngrok config add-authtoken <token>` once | You, once |

## Troubleshooting

| If this happens | Likely cause | What to check |
|---|---|---|
| No Scan Barcode field | Barcode Client Scripts not loaded/disabled | Hard refresh (Ctrl+F5), then `/app/client-script` — confirm the four barcode scripts are enabled |
| A valid barcode is not found | Barcode not in that item's Barcodes table | Open the Item and add the barcode |
| Barcode Printing image is broken | Image-rendering deps on the server | `setup.ps1 -VerifyOnly`, then `docker logs comp_demo-bench-1` |
| Everything is empty after a restart | tmpfs DB wiped | Run `up.ps1` |

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
| Doctype/records are gone | tmpfs DB wiped | Run `up.ps1` |

## Repository layout & other scripts

```
docker-compose.yml        the services (planner build context ./scheduler)
setup.cmd / setup.ps1     idempotent converge + verify of an existing stack (run this daily)
up.ps1                    full bring-up: compose -> bench -> apps -> seed -> Shopify -> planner -> flow -> tunnel -> verify
verify-all.ps1            41-check end-to-end suite (container + HTTP + browser DOM check)
refresh-shopify-token.ps1 re-mints the 24 h Shopify token and rebuilds the Node-RED flow
make-bundle.ps1           clean portable copy + zip + sha256, self-verified
sandbox/                  provisioning scripts, installers, seeders, probes, recipes, node-red flow builder
repos/                    app sources: barcode-shrdc-v16-fixed, shopify-shrdc-v16-fixed, eu_einvoice
scheduler/                the planner: server.js, prebuilt frontend/build, runtime-deps, ui-tests
.opencode/                opencode agents + skills (erpnext-planner, module-*, erpnext-test-runner)
docs/                     guides + MILESTONES.md (status, fixes, known gaps)
```

Status of every milestone, the fixes applied, and the honest not-ready list: [`docs/MILESTONES.md`](docs/MILESTONES.md).
