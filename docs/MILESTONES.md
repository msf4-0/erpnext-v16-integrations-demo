# comp_demo Ã¢â‚¬â€ milestone status (the "complete demo" checklist)

## Project layout Ã¢â‚¬â€ self-contained

Everything needed to rebuild and verify the demo lives **inside `F:\ERPNEXT\erpnext-build`**
(~36 MB / 1.5k files). Nothing is read from `ERPNEXT-AI-FIX` any more.

| Path | What it is |
|---|---|
| `docker-compose.yml` | the whole stack; the planner's build context is `./scheduler` |
| `.env` | ports, site name, Shopify store + client credentials, planner port |
| `up.ps1` | one-command bring-up (11 steps) |
| `verify-all.ps1` | the 41-check end-to-end test (`verify-all-final.log` is the last run) |
| `refresh-shopify-token.ps1` | re-mints the 24 h Shopify token and rebuilds the Node-RED flow |
| `scheduler-up.ps1` | planner-only bring-up (token, seed, desk shortcut, verify) |
| `sandbox/scripts/` | provisioning, install, seeders, probes and the verification suite staged into the container |
| `sandbox/recipes/` | per-app install recipes (`barcode_shrdc`, `shopify`, `eu_einvoice`) |
| `sandbox/node-red/` | flow builder, built `flows.json`, vendored `source-flow.json` export |
| `sandbox/.env.ai-fix` | planner API key/secret + Shopify token shared with the planner script |
| `repos/barcode-shrdc-v16-fixed` | `barcode_shrdc` app source (durable fork with the v16 fixes) |
| `repos/shopify-shrdc-v16-fixed` | `shopify` app source (incl. `shopify/auth.py` token minting) |
| `repos/eu_einvoice` | `eu_einvoice` app source (was still only in ERPNEXT-AI-FIX) |
| `scheduler/` | the production planner: `server.js`, `frontend/` + prebuilt `frontend/build`, `runtime-deps/node_modules`, `ui-tests/` |
| `docs/` | this file + `WINDOWS-QUOTING.md` |

Host prerequisites (not project files): Docker Desktop, the `ngrok` binary + authtoken,
Node/npm (only to rebuild the planner frontend), Python (only for the Node-RED flow builder).
Two intentional fallbacks remain in the scripts Ã¢â‚¬â€ `up.ps1` step 0 and `scheduler-up.ps1`
still try `F:\ERPNEXT\ERPNEXT-AI-FIX\sandbox` **if** the vendored `sandbox/` is absent.

Last verified: **2026-10-26**, live stack on `F:\ERPNEXT\erpnext-build` (project `comp_demo`).
Full test run: `powershell -File F:\ERPNEXT\erpnext-build\verify-all.ps1` Ã¢â€ â€™ **41 / 41 checks pass**
(log: `comp_demo\verify-all-final.log`). That includes a real-browser DOM check that the
Job Cards are rendered as draggable cards; the drags themselves are proven by
`scheduler/ui-tests/ui-drag-matrix.mjs` and `ui-drag-calendar.mjs`.

## Live endpoints

| Service | URL | Notes |
|---|---|---|
| ERPNext v16 | <http://localhost:8000> | site `frontend`, `Administrator` / `admin` |
| Production planner (drag-and-drop) | <http://localhost:3001> | 12 Work Orders Ã‚Â· 24 Job Cards Ã‚Â· 4 Workstations Ã‚Â· 64 capacity rows Ã‚Â· 1 batch group |
| Node-RED (Shopify bridge) | <http://localhost:1880> | 47-node flow, `/delivery-note`, `/stock-entry`, `/stock-recon` |
| ngrok tunnel | <https://scoreless-barcode-length.ngrok-free.dev> | Ã¢â€ â€™ `localhost:1880`, agent API on **:4040** |
| Shopify storefront | <https://4e1075.myshopify.com> | SHRDC, MYR, 13 products published |

Installed apps: `frappe 16.53.0`, `erpnext 16.52.1`, `barcode_shrdc 0.0.1`, `shopify 0.0.1`, `eu_einvoice 16.3.0`.

## Milestones

| # | Milestone | Status | Evidence (measured, not assumed) |
|---|---|---|---|
| M1 | Node-RED connected | **done** | editor `GET /` 200; 47 nodes in `/flows`; container `curl http://bench:8000/api/method/ping` Ã¢â€ â€™ `{"message":"pong"}`; `POST /delivery-note|/stock-entry|/stock-recon` Ã¢â€ â€™ 200 |
| M2 | ngrok routes + webhooks | **done** | public `GET /` 200; unknown path Ã¢â€ â€™ 404 from Node-RED; all three webhook POSTs 200 **through the tunnel**; 3 `Webhook` records, 0 disabled, 0 pointing at a wrong host |
| M3 | Docker build + stack live | **done** | 6 containers running (bench, db, redis Ãƒâ€”2, node-red, scheduler); ping 200; all 5 apps + `Virtual Work Order` / `Barcode Printing` / `Shopify Access` / `E Invoice Settings` present |
| M4 | Shopify item/supplier/customer edits **and live push** | **done (push now live)** | Item create Ã¢â€ â€™ Shopify product `15435533484168` (`status=active`); Item edit Ã¢â€ â€™ Shopify price `27.75` + title updated; Customer create Ã¢â€ â€™ Shopify customer `31339731255432`; Supplier create+edit with **0** error-log rows; cleanup deletes the product in both systems |
| M5 | Storefront has the products | **done** | `GET https://4e1075.myshopify.com/` 200 and `/products/planner-assembly-kit` 200; Admin API shows 13 `ACTIVE` products all with `publishedAt` set |
| M6 | Planner + full build workflow | **done** | 12 WOs Ã‚Â· 24 JCs Ã‚Â· 4 workstations Ã‚Â· 6 submitted BOMs Ã‚Â· 64 `Job Card Scheduled Time` rows; `/api/schedule` returns 12/24/4/1 |
| M7 | Drag-and-drop production planning | **done** | **API:** WO drag Ã¢â€ â€™ `planned_start_date` +2 days, `modified_by=planner@ai-fix.local`, blocks 4Ã¢â€ â€™4, rows 64Ã¢â€ â€™64; JC drag Ã¢â€ â€™ 3 blocks kept, parent WO carries a real clock time. **Real UI (headless Chrome):** matrix drag of `PO-JOB00002` Ã¢â€ â€™ `PUT Ã¢â‚¬Â¦ {"type":"jobcard","docName":"PO-JOB00002","start":"2026-10-28 14:10:00"} ` Ã¢â€ â€™ 200, toast *"Ã¢Å“â€œ Ã¢â‚¬Â¦ [JC: PO-JOB00002] & parent WO: MFG-WO-2026-00001 rescheduled"*, and all three capacity blocks shifted **together** (170/540/490 min preserved); calendar drag of `PO-JOB00001` Ã¢â€ â€™ 200 through the FullCalendar `eventDrop` path. Both restored. |
| M8 | Barcode scanning incl. changed barcode/QR values | **done** | CODE128 / CODE39 / EAN13 Ã¢â€ â€™ three distinct PNGs; a changed value Ã¢â€ â€™ different PNG; invalid EAN13 (`123`) **rejected with a message**; QR rendered per item; `/files/*.png` served as `image/png` |
| M9 | Barcode/QR item tracking | **done** | `scan_barcode` resolves `SHRDC-BRK-0001 Ã¢â€ â€™ PLN-BRACKET` and `SHRDC-KIT-0001 Ã¢â€ â€™ PLN-KIT`, unknown Ã¢â€ â€™ empty; HTTP endpoint 200; Delivery Note `MAT-DN-2026-00001` submitted with `barcode_validation` and `checking_qty == qty`; Stock Entry `MAT-STE-2026-00003` submitted with `scan_stock_entry_barcode`; guest `/item_qr?item_code=PLN-BRACKET` Ã¢â€ â€™ 200 |
| M9b | Scanned-quantity rule enforced **server-side** | **done** | a Delivery Note with `barcode_validation`, `qty 2` but `checking_qty 1` is rejected on submit with `ValidationError: Barcode validation failed Ã¢â‚¬Â¦ row 1 (PLN-BRACKET): qty 2.0 vs checked 1.0` Ã¢â‚¬â€ a REST submit can no longer bypass it |
| M10 | Live local demo + result list | **done** | this document + `verify-all.ps1` |
| Ã¢â‚¬â€ | E-invoicing (extra) | **done** | EN 16931 invoice Ã¢â€ â€™ 4 835-byte UN/CEFACT CII XML (`CrossIndustryInvoice`, `en16931`); XRECHNUNG invoice auto-attaches `ACC-SINV-2026-00001.xml` (4 835 B) |

## The headline fix: Shopify push went live

The previous session's only hard blocker was *"Shopify push is blocked Ã¢â‚¬â€ the token on
the machine returns 401"*. The store's custom app issues **24-hour** client-credentials
tokens, so a single pasted `shpat_...` value can never stay valid.

| Layer | What changed | File |
|---|---|---|
| Token minting | new `shopify/auth.py` mints `POST /admin/oauth/access_token` (`grant_type=client_credentials`), caches the token in Redis until 5 min before expiry, clears the "paused" gate on success, and never raises into a save hook | `repos/shopify-shrdc-v16-fixed/shopify/auth.py` |
| Single choke point | `get_shopify_access()` stamps the live token onto `doc.access_token`/`doc.secret_key` in memory, so every existing handler keeps working; `api.py` now routes its three direct `get_doc` lookups through it | `shopify/utils.py`, `shopify/api.py` |
| Credentials | `SHOPIFY_CLIENT_ID` / `SHOPIFY_CLIENT_SECRET` in `comp_demo/.env` + `sandbox/.env.ai-fix`, persisted into the site's `site_config.json` by `shopify_sync.py` (args 4/5) | `sandbox/scripts/shopify_sync.py`, `sandbox/scripts/ai-fix-postsetup.sh`, `comp_demo/up.ps1` |
| Ops | `comp_demo/refresh-shopify-token.ps1` re-mints, rewrites `.env`, re-verifies `/shop.json` and rebuilds the Node-RED flow (the flow bakes the token into its Shopify nodes) | `comp_demo/refresh-shopify-token.ps1`, `sandbox/scripts/shopify-token.py` |

## Other fixes applied this session

### 1. Demo data was seeded before its dependencies existed (build order)
`up.ps1` ran `seed-demo-masters.py` at step **7c**, but that script needs the Company,
chart of accounts and the `PLN-*` Items that are created in step **8** (Shopify
post-setup). Every demo document failed with `Could not find Company: SHRDC`.
Now: `8b` (demo master data, after the Shopify sync) and `9b` (`Virtual Work Order`
schema + demo batch group, after the planner seeds Work Orders). Seeder now reports
**0 errors** Ã¢â‚¬â€ 3 supplier groups, 9 stock entry types, 4 enabled client scripts,
2 item barcodes, 1 Barcode Printing, 3 Stock Entries, 1 Delivery Note, 1 Sales Invoice.

### 2. `Virtual Work Order` doctype was missing (planner batch/timers tabs)
`scheduler/server.js` reads and writes `/Virtual Work Order` for batch groups, timers
and the schedule feed, and the doctype existed in no app. `sandbox/scripts/seed-vwo-doctype.py`
creates it (parent + child table, submittable, `VWO-.####` naming) and a demo batch
group from two real Work Orders Ã¢â€ â€™ `/api/batch-work-orders` returns `VWO-0001`.

### 3. ERPNext refused to save any Job Card after the first operation
`JobCard.validate_sequence_id` rejects a save whenever the previous operation has no
`completed_qty`. A Work Order drag therefore updated **1 of 2** Job Cards ("1 linked
Job Card(s) updated") and left the rest of the routing behind. The planner now writes
the schedule through the whitelisted Server Script `planner_shift_job_card`
(child rows via `frappe.db.set_value`), falling back to the validated `PUT` only if
that endpoint is unavailable. Requires `bench set-config -g server_script_enabled 1`
Ã¢â‚¬â€ now done by `ai-fix-postsetup.sh`.

### 4. `/api/work-orders/timers` was shadowed by `/api/work-orders/:id`
Express matched the `:id` route first, looked up a Work Order literally named
"timers" and answered 500. Route-order guard added in `scheduler/server.js`.

### 5. Sales Forecast tab answered 403
The planner user only held Manufacturing roles. `ai-fix-scheduler-token.py` now also
grants **Sales User** + **Stock User**.

### 6. EAN13 printed a different code instead of failing
reportlab pads short numeric values, so `EAN13("123")` produced a label that scans as
something else. `get_barcode_image()` now validates the digit count (13 or 12 for
EAN13, 8 for EAN8/UPCE, 12 for UPCA) and throws a readable message.

### 7. Shopify payloads broke on empty numeric fields
`int(inventoryNum)` raised `TypeError` for an item with no opening stock, and `null`
`price`/`weight` make Shopify answer 422. `create_product.py` / `update_product.py`
now coerce numerics, stay silent on success, and only log failures.
`update_product_inventory.py` sent **no** `X-Shopify-Access-Token` header at all; fixed
(and the hook is still not wired to Stock Ledger Entry Ã¢â‚¬â€ see below).

### 8. Guest checkouts created 250 identical customers
`f"{first_name} {last_name}"` rendered `None` and the fallback name was a constant, so
every guest order added another "Shopify Customer None". Both customer-creation paths
now name guests `Shopify Guest <last4 of id>` (or their email), and
`fix-shopify-customers.py` renamed the 252 rows that already existed.

### 9. The scanned-quantity rule was client-side only
`checking_qty == qty` shipped as a Client Script `before_submit`, so any REST submit
skipped it. `barcode_shrdc/validators.py` (hooked in `hooks.py` for Delivery Note and
Stock Entry `before_submit`) now enforces it server-side, and only when the document
sets `barcode_validation` / `scan_stock_entry_barcode` Ã¢â‚¬â€ verified by submitting a
deliberately mismatched Delivery Note, which is rejected.

### 10. Job Cards could not be dragged in the UI (there were no Job Card cards)
`Scheduler.jsx` built its event list from **`orphanedJobCards`** Ã¢â‚¬â€ Job Cards with no
loaded Work Order Ã¢â‚¬â€ so in this demo *zero* Job Cards became events; they only appeared
as text inside the Work Order card. Two fixes:
- every Job Card is now its own event (`id: jc-<name>`, `type: "jobcard"`), rendered by
  the existing `.card-jobcard` markup with `draggable` and the existing JC drop handlers;
- the calendar view filter gained a **Job Cards** option.
Verified in headless Chrome: 12 Job Card cards in the matrix (all `draggable=true`),
23 Job Card events in the calendar, both drag paths issue
`PUT Ã¢â‚¬Â¦ {"type":"jobcard"}` Ã¢â€ â€™ 200 and move every capacity block. Repeatable checks live
in `scheduler/ui-tests/` (`ui-cards.mjs` is read-only and is part of `verify-all.ps1`).

### 11. The SPA was built against the standalone app's API URL
`scheduler/frontend/.env` still said `REACT_APP_API_URL=http://localhost:3500/api` and
`REACT_APP_ERPNEXT_URL=http://localhost:8080`, and the Dockerfile's build args are not
consumed (the bundle is built on the host and COPYed). The shipped bundle therefore
called a port nothing listens on: *"Connection Error: Failed to fetch"*, 0 stations,
empty matrix. `.env` now sets `REACT_APP_API_URL=/api` (same Express serves UI + API)
and `REACT_APP_ERPNEXT_URL=http://localhost:8000` (browser-facing links).

## How to re-verify

```powershell
# everything (41 checks, ~5 min; creates and deletes a throwaway AI-VERIFY-* item)
powershell -ExecutionPolicy Bypass -File F:\ERPNEXT\erpnext-build\verify-all.ps1

# frappe-level half only, inside the container
docker exec comp_demo-bench-1 bash -lc 'cd /home/frappe/frappe-bench && \
  SITE_NAME=frontend PLANNER_URL=http://scheduler:3000 ./env/bin/python /tmp/scripts/verify-milestones.py'
```

Supporting probes (all read-only unless stated): `probe-state.py` (full site snapshot),
`probe-duplicates.py` (duplicate imported docs), `probe-drag.py` (per-block drag diff,
restores itself), `shopify-token.py status|refresh|verify`, `fix-demo-data.py` (removes
test suppliers, repairs an out-of-sequence WO Ã¢â‚¬â€ idempotent).

## Not ready / known gaps

| Item | Why | What unblocks it |
|---|---|---|
| One capacity block short of a fresh build (64 vs 65) | consumed by the pre-fix drag while the defect was being reproduced Ã¢â‚¬â€ precisely the loss the fix removes | rebuild with `up.ps1` (~25Ã¢â‚¬â€œ35 min) or re-seed the planner |
| Stock reconciliation does not push stock to Shopify | `update_product_inventory.on_submit` is not wired in `hooks.py` (the header bug is fixed) | add a `Stock Ledger Entry` doc_event if push-on-stock is wanted |
| Malaysia (LHDN) e-invoicing | the substituted app is EU EN 16931 / XRechnung (CII), not MyInvois; the original MY source is 404 | supply the MY app source |
| Timers tab shows an empty object | `/api/work-orders/timers` now answers 200 but no Work Order has a running timer until someone clicks **Start** in the planner | start a timer in the UI (state is the planner's own `timers.json`) |
| Anything after `docker compose down` / engine restart | the DB is **tmpfs** on purpose (>300 s/100 tables on a volume vs 0.20 s on tmpfs) | rerun `powershell -File F:\ERPNEXT\erpnext-build\up.ps1` (~25Ã¢â‚¬â€œ35 min) |

### Operational gotchas

- **Shopify tokens expire in 24 h.** The ERPNext side re-mints by itself; the Node-RED
  flow bakes the token into its nodes, so run
  `powershell -File F:\ERPNEXT\erpnext-build\refresh-shopify-token.ps1` daily (or schedule it).
- **Server Scripts must stay enabled** (`server_script_enabled = 1` in
  `common_site_config.json`) or the planner falls back to a validated `PUT` and a Work
  Order drag will only move its first operation.
- `docker restart comp_demo-bench-1` kills `bench serve` (it is started with
  `setsid nohup`, not by the entrypoint). Restart it with:
  ```bash
  docker exec comp_demo-bench-1 bash -lc "cd /home/frappe/frappe-bench && setsid nohup bench serve --port 8000 >/tmp/bench-serve.log 2>&1 &"
  ```
- After editing an app's `.py` files inside the container, `docker compose restart
  bench` is **not** enough Ã¢â‚¬â€ the site's Flask dev server reloads on change, but
  `bench --site frontend clear-cache` is needed after installing fixtures/doctypes.
