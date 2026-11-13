# Architecture and state map

What runs, where its state lives, and what a `docker compose down` actually
costs you. If you are about to run a destructive command, read the matrix first.

Compose project: `comp_demo` · site: `frontend` · host ports: 8000 (ERPNext),
3001 (planner), 1880 (Node-RED), 3005 (Metabase).

## Services

| Service | Image | Role | Depends on |
|---|---|---|---|
| `bench` | `comp_demo-bench:v16` (built from `bake/bench.Dockerfile`) | ERPNext v16 + frappe + barcode_shrdc + shopify + eu_einvoice + render deps | db, redis-cache, redis-queue (healthy) |
| `db` | `mariadb:11.8` | site DB **and** Metabase metadata | – |
| `redis-cache` | `redis:6.2-alpine` | frappe cache | – |
| `redis-queue` | `redis:6.2-alpine` | background jobs | – |
| `node-red` | `nodered/node-red:latest` | Shopify ↔ ERPNext bridge | bench (started) |
| `scheduler` | `comp_demo-scheduler:latest` | production planner (Express + React) | bench (started) |
| `metabase` | `metabase/metabase:v0.58.38.2` | BI dashboard | db (healthy) |

There is **no** `ngrok` service. The tunnel is the host's ngrok binary, started
by `up.ps1` / `setup.ps1`, and it is the one moving part that is not a container.

## Where state lives

| State | Location | Kind |
|---|---|---|
| Site database (all DocTypes, transactions) | `db_data` | named volume |
| Metabase app metadata (admin user, data source, dashboards) | `metabase` schema inside `db_data` | named volume |
| Site files, `site_config.json`, `apps.txt`, private/public files | `bench_sites` | named volume |
| Node-RED flows | `node_red_data` | named volume |
| `item_tracking`, `metabase_integration`, `barcode_shrdc` source | `./repos/*` on the host | bind mount |
| frappe, erpnext, shopify, eu_einvoice, venv, pip packages, redis-server | inside the image | image layer |
| `*.pth`, `/assets/<app>` symlinks, DB grant | container layer | **rebuilt on every start** by the `bench` `command:` |
| Planner timers (`timers.json`) | `scheduler` container layer | **no volume** |
| ngrok tunnel + webhook URLs | host process + `Webhook` records in the DB | **not durable** |

## Survive matrix

| Event | Site DB | Site files | Apps | Metabase | Flows | Tunnel/webhooks | Planner timers |
|---|---|---|---|---|---|---|---|
| `docker restart comp_demo-bench-1` | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ tunnel stays, points at nothing while bench is down | ✅ |
| `docker compose stop` / `start` | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ webhooks point at a dead URL | ✅ |
| `docker compose down` (no `-v`) | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ URL changes, must re-wire | ❌ lost |
| `docker compose down -v` | ❌ | ❌ | ✅ (image) | ❌ | ❌ | ❌ | ❌ |
| `up.ps1 -Fresh` | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Rebuild the bench image | ✅ | ✅ | ✅ (from `repos/`) | ✅ | ✅ | ❌ | ✅ |

**The short version:** `down` without `-v` keeps your data and your apps. What it
does *not* keep is the Shopify/ngrok wiring — the public URL changes, so the
three ERPNext `Webhook` records point at a host that no longer answers. Recovery
is `setup.ps1`, not `up.ps1` (2–4 min, no rebuild).

`down -v` throws everything away and is only recoverable with a full `up.ps1`
(25–35 min) or a restore from `bench backup`.

## First boot vs. restart

- **Fresh volume** (`bench_sites` empty): `bench serve` answers
  `404 localhost does not exist`. There is no site yet. Only provisioning
  (`up.ps1`) or a restore creates one. A plain `docker compose up` on a fresh
  clone is therefore *not* a working stack — this is why `bake/README.md` no
  longer claims otherwise.
- **Existing volume**: the container's `command:` block re-asserts the DB grant,
  rewrites the `.pth` files, recreates `/assets/<app>` aliases, then starts
  `bench schedule`, a worker, and `bench serve`. No manual step needed.

## What proves a feature works

`up.ps1` ends with these; each one is a hard failure, not a warning:

| Feature | Check |
|---|---|
| ERPNext serving | `GET /api/method/ping` → 200 |
| Barcode app installed | `GET /api/resource/Barcode Printing` (token) → 200 |
| Barcode page renders | `GET /item_qr?item_code=PLN-BRACKET` → 200 |
| Individual item tracking | `GET /assets/item_tracking/js/item_tracking_scan.js` → 200 |
| E-invoicing | `GET /api/resource/E Invoice Import` (token) → 200 |
| Planner | `GET :3001/api/health` → `{status: ...}` |
| Tunnel + webhooks | `POST <public>/delivery-note`, `/stock-entry`, `/stock-recon` → 200 |
| Full suite | `verify-all.ps1` (41 checks) |

A homepage 200 proves none of the above — an app whose `app_include_js` 404s
still returns a 200 HTML shell.

## Optional: Malaysia LHDN / MyInvois (`repos/my_invois`)

`eu_einvoice` implements the **EU** EN 16931 / XRechnung standard. `my_invois`
is the Malaysian layer (TIN/BRN/SST custom fields, e-invoice status lifecycle,
explicitly gated submission - never a side effect of saving).

It is **mounted but not installed**: installing it next to `eu_einvoice` adds a
second e-invoice doctype set and the two standards do not share a profile model.
Pick one per site.

To install it deliberately:

```bash
docker exec comp_demo-bench-1 bash -lc "cd /home/frappe/frappe-bench \
  && ./env/bin/pip install -e apps/my_invois \
  && bench --site frontend install-app my_invois \
  && bench --site frontend migrate \
  && bench --site frontend clear-cache"
docker restart comp_demo-bench-1
```

Then set the LHDN credentials in **MyInvois Settings** and submit a Sales
Invoice from the *MyInvois* tab. Without credentials, submission stays disabled
by design.