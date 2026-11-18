# Installation — existing-build integration and Windows shell quoting

## Adding the missing functions to an existing ERPNext v16 build

> **HISTORICAL GUIDE — not the onboarding path for this repository.**
> This document describes the old `erpnext-build.zip` bundle (different folder
> name, different `.env`). For a `git clone` of this repo, follow
> [`README.md`](../README.md) section 3 and run `.\setup\up` from the repo root.
> The `setup/up` it references belonged to the retired `erpnext-fix`
> project and no longer exists.

> Authoritative stack architecture, ports, versions, and database durability:
> [`ARCHITECTURE.md`](ARCHITECTURE.md).

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

### Path A — just run the whole stack (30 minutes, nothing to integrate)

Safest option: it comes up on its own ports and never touches your site.

```bash
unzip erpnext-build.zip
cd erpnext-build

**The two flow-path lines in `.env` may stay blank** (they self-resolve inside the repo). If you did set them,
otherwise the Node-RED container mounts nothing:

    FLOWS_PATH=
    NODE_RED_SOURCE_FLOW=
    # Both may stay blank: they resolve to the vendored
    # sandbox/node-red/*.json inside this repo. Never hard-code a machine path.

cp .env.example .env
#    The defaults boot as-is. Optional extras: SHOPIFY_STORE, SHOPIFY_CLIENT_ID,
#    SHOPIFY_CLIENT_SECRET, NGROK_AUTHTOKEN. Leave them blank to skip those
#    integrations - a blank value is reported as SKIPPED, not as a failure.

powershell -ExecutionPolicy Bypass -File .\setup\up          # Windows: full integration setup
bash ./up-linux.sh                                         # Linux: core ERPNext site
bash ./install-apps-linux.sh                               # Linux: install custom apps
```

The Linux commands install the custom apps but do not configure the planner,
Metabase, Node-RED, Shopify credentials, ngrok, or demo data. The full
integration workflow is currently orchestrated by the PowerShell scripts.

After the full Windows setup: ERPNext <http://localhost:8000> (Administrator/admin) ·
planner <http://localhost:3001> · Node-RED <http://localhost:1880>. Verify with
`setup/verify-all` (41 checks).

> The site DB is stored in the `db_data` named volume and survives container and Docker restarts.
> From the repo root, `docker compose --env-file .env --env-file versions.env down -v` removes that volume.
> See [`ARCHITECTURE.md`](ARCHITECTURE.md).

---

### Path B — graft onto your existing v16 bench

Below, `<site>` is your site name (`bench --site <site> ...`) and `<bench>` is your bench dir
(usually `/home/frappe/frappe-bench`). Add `--user frappe` / `sudo -u frappe` if you run as root.

#### B1. Copy the three apps into your bench host

```bash
cp -r erpnext-build/repos/barcode-shrdc-v16-fixed   /tmp/barcode_shrdc
cp -r erpnext-build/repos/shopify-shrdc-v16-fixed   /tmp/shopify
cp -r erpnext-build/repos/eu_einvoice               /tmp/eu_einvoice
```

#### B2. Install them

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

#### B3. One-time site setup (do not skip — these are the bugs that were fixed)

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

#### B4. A user for the planner (least privilege)

```bash
SITE_NAME=<site> ./env/bin/python erpnext-build/sandbox/scripts/fix-scheduler-token.py
# prints PLANNER_API_KEY=... PLANNER_API_SECRET=...
```

It creates `planner@fix.local` with Manufacturing Manager/User + Sales User + Stock User —
the planner needs all three (Sales for the forecast tab, Stock for stock lookups).

#### B5. Run the planner

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

#### B6. Node-RED (the Shopify ↔ ERPNext bridge)

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
  the Node-RED image pinned by `versions.env`
```

Check <http://localhost:1880> (editor) and that the flow has ~47 nodes. Its endpoints are
`/delivery-note`, `/stock-entry`, `/stock-recon`:

```bash
curl -X POST http://localhost:1880/delivery-note -H 'Content-Type: application/json' -d '{}'
# expect 200
```

#### B7. ngrok + webhooks

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
`erpnext-build/sandbox/scripts/fix-wire-webhooks.sh <public-url>` does the same three records
if your bench layout matches ours.

Test through the tunnel, not locally:

```bash
curl -X POST https://<your-tunnel>.ngrok-free.app/delivery-note -H 'Content-Type: application/json' -d '{}'
```

Free ngrok gives you **one** tunnel per agent, and the URL changes on restart — re-point the
webhooks each time (or use a reserved domain).

#### B8. E-invoicing

`eu_einvoice` adds `E Invoice Settings` (singleton) and an `einvoice_profile` field on Sales
Invoice.

1. Fill company address, tax ID and the seller contact details — the CII XML needs them.
2. `E Invoice Settings` → turn on **auto_attach_xml** if you want the XML attached on submit.
3. On a Sales Invoice choose profile **EN 16931** or **XRECHNUNG**, submit, then check the
   attachments: an `.xml` of a few KB with `urn:cen.eu:en16931` inside.

> This is **EU** e-invoicing (EN 16931 / XRechnung), not Malaysian LHDN MyInvois.

#### B9. Shopify (your own keys)

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

### Smoke test after B1–B9

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

### Gotchas that cost real hours

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
6. **Don't run `setup/up` against your own site.** It creates its own compose project (`comp_demo`)
   and uses the durability configured for that existing bench; Path B is the integration path.
7. **Planner API user needs 3 role families** (Manufacturing, Sales, Stock) or the forecast/batch
   tabs answer 403 — `fix-scheduler-token.py` grants them.

---

### What is NOT in the zip, on purpose

- **Your Shopify keys** — client id/secret and store, as above.
- **Malaysian LHDN MyInvois** — the e-invoicing app here is EU EN 16931. The original MY source
  404s; if you need MyInvois that is a different app.
- **`scheduler/frontend/node_modules` (generated by `npm ci`; not tracked)** (~300 MB) — only needed if you want to *change* the planner
  UI: `cd scheduler/frontend && npm ci && npm run build`. The compiled bundle is included.

Questions on any step, ping me — the working reference stack is the same zip, so I can tell you
exactly which file does what.

## Windows / PowerShell -> `docker compose exec` quoting: rules for future runs

All sandbox commands run from a Windows PowerShell 5.1 host into a Linux
container via `docker compose -p comp_demo exec <svc> bash -lc "..."`.
That is 3-4 interpolation layers (PowerShell -> docker CLI -> bash -> the
Python/JSON/SQL/JS that bash then runs). Each layer mangles characters before
the next sees them. These rules were extracted from a run that hit every one
of them; follow them to avoid repeating the failures.

### Rules

For examples that truly need an absolute Windows path, mark it as a Windows-host
path (for example, `F:\ERPNEXT\erpnextcomp_demo\up.ps1` (Windows host)). In normal
runbooks, prefer paths relative to the repository root.

1. **Never put multi-line or quote-heavy bash inline.** Write a SCRIPT file
   and run it. That is exactly what `provision-base.sh`, `install-app.sh`, and
   `ensure-root-prep.sh` exist for. Inline `bash -lc "..."` is only safe for a
   single simple command with no `$()`, no nested quotes, no backticks.

2. **Outer-quote with SINGLE quotes:** `bash -lc '...'`. Double quotes let
   PowerShell expand `$VAR`, `$(...)` and backticks *before* bash runs.

3. **Do NOT use `$(...)` or backticks in inline bash.** PowerShell eats them.
   - Symptom: ``unexpected EOF while looking for matching `)``
   - Backtick is PowerShell's escape char, so SQL like
     ``SELECT ... FROM `tabCustom Field` `` reaches the DB as `tabCustom`.
   - Fix: put the command in a script file, or base64 it (rule 5).

4. **Avoid `printf "\n"` inline** (the backslash gets stripped, so it appends a
   literal `n` -> `erpnextnbarcode_shrdc`). Use `echo >> file`, or a script
   file, or base64.

5. **For multi-line Python/SQL, BASE64 it** — the reliable escape hatch when
   everything else fails. It collapses all layers to one unbroken token:
   ```powershell
   $py = @'
   import frappe
   def run():
       print("hello from inside")
   '@
   $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($py))
   docker compose -p comp_demo exec bench bash -lc "echo $b64 | base64 -d > /tmp/x.py && cd /home/frappe/frappe-bench && env/bin/python /tmp/x.py"
   ```
   Same pattern for SQL (decode into a file, then `mariadb ... < file.sql`).

6. **Inside the container, use Linux tools** (`grep`, `sed`, `awk`, `tail`).
   PowerShell cmdlets (`Select-String`, `Get-*`) are host-only and fail with
   `bash: Select-String: command not found`.

7. **`bench execute` needs the target importable from an INSTALLED app
   package.** Put a `helper.py` inside `apps/<app>/<pkg>/` and call
   `<pkg>.<helper>.run`; a bare `/tmp/foo.py` or a module under `frappe/`
   fails with `App <name> is not installed` / `NameError`. Do **not** use raw
   `frappe.init()/connect()` scripts launched via `env/bin/python` — that dies
   with `FileNotFoundError: /home/frappe/logs/database.log` unless a full bench
   context exists. Go through `bench --site frontend execute <path>`.

8. **Backgrounding:** a `&`-ed process is killed when the exec session ends,
   and `nohup ... &` without `setsid`/stdin redirect can keep the exec pipe
   open so the tool call appears to hang. Use:
   ```
   setsid nohup <cmd> > /tmp/x.log 2>&1 < /dev/null & disown
   ```
   then verify in a **separate** exec (`curl` ping / `tail` the log).

9. **The db container's client is `mariadb`, not `mysql`.** The DB name is a
   random hash — read it from `sites/<site>/site_config.json`, don't guess it.

10. **`docker compose cp` does NOT overwrite existing files** (a nested
    `lib/common.sh` silently stayed stale). Copy each file individually, and
    `docker compose exec ... mkdir -p` the target dir first.
    - **Corollary — `cp <dir> <existing-dir>` NESTS, it does not merge.**
      `docker compose cp bench:/tmp/final-app/robotics_lab ./repos/robotics_lab`
      created `./repos/robotics_lab/robotics_lab/...` *inside* the existing
      directory, leaving a duplicated app tree (two `hooks.py`, two
      `device.json`). `detect_pth_target` picks `find ... -name hooks.py |
      head -n1`, so with duplicates the resolved `.pth` target depends on
      filesystem ordering — a latent break.
      **Always copy with the trailing `/.` to merge into the destination:**
      `docker compose cp bench:/tmp/final-app/robotics_lab/. ./repos/robotics_lab`
      and keep exactly ONE `hooks.py` in the tree. For a guaranteed-clean
      layout, tar it in the container and extract once on the host.

11. **Newer bench keeps only `sites/apps.txt`** (no root `apps.txt`). Any
    registration code must tolerate either (see `register_app_by_hand()` in
    `install-app.sh`).

### Quick self-check before running an inline command

If the command contains any of: `$`, `(`, `)`, backtick, `!`, a newline, or a
quote nested inside another quote of the same type -> it will likely break.
Move it into a script file or base64 payload.
