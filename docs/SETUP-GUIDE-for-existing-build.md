# Adding the missing functions to an existing ERPNext v16 build

You got **`erpnext-build.zip`** (≈8 MB). It is not a plugin: it is a complete,
self-contained demo of the same four things, plus the exact source of each piece so you can
either run it whole or graft the pieces into your own site.

| What it adds | Where it lives in the zip |
|---|---|
| Drag-and-drop production planner (Work Orders **and** Job Cards) | `scheduler/` |
| Shopify bridge (ERPNext → Shopify push, 24 h tokens self-minted) | `repos/shopify-shrdc-v16-fixed/` |
| Barcode / QR printing + scanning + item tracking | `repos/barcode-shrdc-v16-fixed/` |
| EU e-invoicing (EN 16931 CII XML, XRECHNUNG auto-attach) | `repos/eu_einvoice/` |
| Node-RED flow + builder, ngrok wiring, seeders, probes | `sandbox/` |

**Check the version first.** Everything here is built for **ERPNext v16** (`bench version` →
`erpnext 16.x`). On v14/v15 the apps will not install.

---

## Path A — just run the whole stack (30 minutes, nothing to integrate)

Safest option: it comes up on its own ports and never touches your site.

```bash
unzip erpnext-build.zip
cd erpnext-build

**Two lines in `.env` are absolute paths** - point them at wherever you unzipped this,
otherwise the Node-RED container mounts nothing:

    FLOWS_PATH=F:/path/to/erpnext-build/sandbox/node-red/flows.json
    NODE_RED_SOURCE_FLOW=F:\path\to\erpnext-build\sandbox\node-red\source-flow.json
cp .env.example .env
cp sandbox/.env.ai-fix.example sandbox/.env.ai-fix
#    fill in .env:  DB_ROOT_PASSWORD, SHOPIFY_STORE, SHOPIFY_CLIENT_ID, SHOPIFY_CLIENT_SECRET
#    (NGROK_AUTHTOKEN optional - it falls back to your ngrok config)

powershell -ExecutionPolicy Bypass -File .\up.ps1          # Windows
# bash ./sandbox/up.ps1                                     # Linux/macOS equivalent
```

Then: ERPNext <http://localhost:8000> (Administrator/admin) · planner <http://localhost:3001> ·
Node-RED <http://localhost:1880>. Verify with `verify-all.ps1` (41 checks).

> The site DB is **tmpfs on purpose** — stopping the containers wipes the site. That is why the
> project is *rebuildable*: `up.ps1` recreates and re-seeds everything.

---

## Path B — graft onto your existing v16 bench

Below, `<site>` is your site name (`bench --site <site> ...`) and `<bench>` is your bench dir
(usually `/home/frappe/frappe-bench`). Add `--user frappe` / `sudo -u frappe` if you run as root.

### B1. Copy the three apps into your bench host

```bash
cp -r erpnext-build/repos/barcode-shrdc-v16-fixed   /tmp/barcode_shrdc
cp -r erpnext-build/repos/shopify-shrdc-v16-fixed   /tmp/shopify
cp -r erpnext-build/repos/eu_einvoice               /tmp/eu_einvoice
```

### B2. Install them

```bash
cd <bench>
bench get-app /tmp/barcode_shrdc
bench get-app /tmp/shopify
bench get-app /tmp/eu_einvoice
bench --site <site> install-app barcode_shrdc
bench --site <site> install-app shopify
bench --site <site> install-app eu_einvoice
bench --site <site> migrate
bench --site <site> list-apps          # expect all three installed
bench restart                          # or: bench --site <site> clear-cache
```

### B3. One-time site setup (do not skip — these are the bugs that were fixed)

The scripts assume the standard bench path `/home/frappe/frappe-bench`. If yours differs, edit
the `os.chdir(...)` line at the top of each script first. Run them with the bench venv python:

```bash
cd <bench>
cp erpnext-build/sandbox/scripts/fix_shopify_show_in_website.py .
cp erpnext-build/sandbox/scripts/seed-demo-masters.py .
cp erpnext-build/sandbox/scripts/seed-vwo-doctype.py .

# 1. the shopify app reads Item.show_in_website, which v16 does not have:
#    without this every Item save dies with AttributeError.
SITE_NAME=<site> ./env/bin/python fix_shopify_show_in_website.py

# 2. barcode client scripts (they ship disabled), Supplier Group, Stock Entry Type,
#    item barcodes and demo documents. Optional - skip if you do not want demo data.
SITE_NAME=<site> ./env/bin/python seed-demo-masters.py

# 3. REQUIRED for the planner: Virtual Work Order doctype + the Server Script that
#    makes a Job Card drag persist (see the gotcha at the end).
SITE_NAME=<site> ./env/bin/python seed-vwo-doctype.py

# 4. that Server Script only runs when Server Scripts are enabled:
bench set-config -g server_script_enabled 1
bench --site <site> clear-cache
```

### B4. A user for the planner (least privilege)

```bash
SITE_NAME=<site> ./env/bin/python erpnext-build/sandbox/scripts/ai-fix-scheduler-token.py
# prints PLANNER_API_KEY=... PLANNER_API_SECRET=...
```

It creates `planner@ai-fix.local` with Manufacturing Manager/User + Sales User + Stock User —
the planner needs all three (Sales for the forecast tab, Stock for stock lookups).

### B5. Run the planner

The planner is a separate Express + React service (not a Frappe app). The image is built from
`scheduler/`, which already ships `frontend/build` and `runtime-deps/node_modules`:

```bash
cd erpnext-build/scheduler
docker build -t erpnext-planner .
docker run -d --name erpnext-planner -p 3001:3000 \
  -e ERPNEXT_URL=http://<host-ip>:8000 \
  -e ERPNEXT_API_KEY=<key>:<secret from B4> \
  -e PORT=3000 erpnext-planner
```

`ERPNEXT_URL` must be reachable **from inside the container** — `http://localhost:8000` means the
container itself. Use the host LAN IP, or put it on the same docker network as your bench and use
`http://<bench-container>:8000`.

Open <http://localhost:3001>: you should see 4 workstation rows and draggable Work Order **and**
Job Card cards. Drag one, the toast confirms, refresh — it stayed.

### B6. Node-RED (the Shopify ↔ ERPNext bridge)

```bash
cd erpnext-build
cp sandbox/node-red/source-flow.json .
python sandbox/node-red/build-flows.py \
  --src source-flow.json --out flows.json \
  --erpnext-url http://<host-ip>:8000 \
  --erpnext-token <key>:<secret>            # an ERPNext API key/secret for the bridge
  --shopify-store yourstore.myshopify.com \
  --shopify-version 2026-04 \
  --shopify-token shpat_xxx                 # optional, see "Shopify" below
  --site <site>

docker run -d --name node-red -p 1880:1880 \
  -v "$PWD/flows.json:/data/flows.json" \
  -e ERPNEXT_INTERNAL_URL=http://<host-ip>:8000 \
  -e SHOPIFY_STORE=yourstore.myshopify.com \
  -e SHOPIFY_API_VERSION=2026-04 \
  nodered/node-red:latest
```

Check <http://localhost:1880> (editor) and that the flow has ~47 nodes. Its endpoints are
`/delivery-note`, `/stock-entry`, `/stock-recon`:

```bash
curl -X POST http://localhost:1880/delivery-note -H 'Content-Type: application/json' -d '{}'
# expect 200
```

### B7. ngrok + webhooks

```bash
ngrok http 1880
# public URL + agent API on http://localhost:4040
```

Point your three ERPNext **Webhook** records at the tunnel (ERPNext → *Webhook*):

| DocType / event | URL |
|---|---|
| Delivery Note · on_submit | `https://<your-tunnel>.ngrok-free.app/delivery-note` |
| Stock Entry · on_submit | `https://<your-tunnel>.ngrok-free.app/stock-entry` |
| Stock Reconciliation · on_submit | `https://<your-tunnel>.ngrok-free.app/stock-recon` |

Set **enabled = 1** and add header `ngrok-skip-browser-warning: 1` in the webhook's headers.
`erpnext-build/sandbox/scripts/ai-fix-wire-webhooks.sh <public-url>` does the same three records
if your bench layout matches ours.

Test through the tunnel, not locally:

```bash
curl -X POST https://<your-tunnel>.ngrok-free.app/delivery-note -H 'Content-Type: application/json' -d '{}'
```

Free ngrok gives you **one** tunnel per agent, and the URL changes on restart — re-point the
webhooks each time (or use a reserved domain).

### B8. E-invoicing

`eu_einvoice` adds `E Invoice Settings` (singleton) and an `einvoice_profile` field on Sales
Invoice.

1. Fill company address, tax ID and the seller contact details — the CII XML needs them.
2. `E Invoice Settings` → turn on **auto_attach_xml** if you want the XML attached on submit.
3. On a Sales Invoice choose profile **EN 16931** or **XRECHNUNG**, submit, then check the
   attachments: an `.xml` of a few KB with `urn:cen.eu:en16931` inside.

> This is **EU** e-invoicing (EN 16931 / XRechnung), not Malaysian LHDN MyInvois.

### B9. Shopify (your own keys)

The app pushes Items/Customers/Sales Orders to Shopify and mints its own Admin API tokens, so you
never paste a `shpat_` value again:

```bash
bench --site <site> set-config shopify_client_id     <your app client id>
bench --site <site> set-config shopify_client_secret <your app client secret>
bench --site <site> set-config shopify_store         yourstore.myshopify.com
bench --site <site> set-config shopify_api_version   2026-04
```

(Shopify admin → Settings → Apps → Develop apps → your app → Client credentials.) Then create one
`Shopify Access` record (Shopify → Shopify Access) pointing at
`https://yourstore.myshopify.com/admin/api/2026-04/`. Edit an Item — a product should appear in
Shopify within a second or two.

---

## Smoke test after B1–B9

```
bench --site <site> list-apps                      # 3 new apps
<planner>:3001/api/health                          # {status: ...}
<planner>:3001/api/schedule                        # workOrders / jobCards arrays
POST http://localhost:1880/delivery-note           # 200
Item save in ERPNext                               # no red dialog, no Error Log row
Delivery Note submit with barcode_validation=1     # rejects qty mismatch
Sales Invoice with einvoice_profile=XRECHNUNG      # .xml attached
```

---

## Gotchas that cost real hours

1. **`server_script_enabled` must be 1.** ERPNext's `JobCard.validate_sequence_id` refuses to save
   any Job Card whose previous operation has no completed qty, so without the Server Script
   `planner_shift_job_card` a Work Order drag moves only its **first** operation. Keep the flag on.
2. **Virtual Work Order doctype is required** for the planner's Batch / Timers tabs and its
   `/api/work-orders/timers` + `/api/batch-work-orders` endpoints. `seed-vwo-doctype.py` creates it.
3. **`Item.show_in_website`** — the shopify app reads it; v16 has no such field. Run
   `fix_shopify_show_in_website.py` **before** touching any Item.
4. **Shopify tokens last 24 h.** The ERPNext side self-mints. The Node-RED flow bakes the token
   into its nodes, so re-run `build-flows.py` + restart node-red when it starts answering 401.
5. **`docker restart <bench>` kills `bench serve`.** Restart it inside the container:
   `cd /home/frappe/frappe-bench && setsid nohup bench serve --port 8000 >/tmp/bench-serve.log 2>&1 &`
6. **Don't run `up.ps1` against your own site.** It creates its own compose project (`comp_demo`)
   and its own tmpfs database; Path B is the integration path.
7. **Planner API user needs 3 role families** (Manufacturing, Sales, Stock) or the forecast/batch
   tabs answer 403 — `ai-fix-scheduler-token.py` grants them.

---

## What is NOT in the zip, on purpose

- **Your Shopify keys** — client id/secret and store, as above.
- **Malaysian LHDN MyInvois** — the e-invoicing app here is EU EN 16931. The original MY source
  404s; if you need MyInvois that is a different app.
- **`scheduler/frontend/node_modules`** (~300 MB) — only needed if you want to *change* the planner
  UI: `cd scheduler/frontend && npm ci && npm run build`. The compiled bundle is included.

Questions on any step, ping me — the working reference stack is the same zip, so I can tell you
exactly which file does what.
