# comp_demo architecture

> **Numbers live in [FACTS.md](FACTS.md).** That page is the single source of truth for versions,
> ports, service count, installed apps and launcher-per-platform, because every value there was
> measured. This document explains the Compose topology and why it is shaped that way; it must not
> state a number that contradicts FACTS.md or `docker-compose.yml`.

## Scope and canonical location

The project is the repository root, with Docker Compose project name `comp_demo`
and ERPNext site `frontend` by default. Run commands from the repository root;
paths in this document are repository-relative. `docker-compose.yml` is the
authoritative definition of the container stack. The PowerShell entry points
`up.ps1` and `setup.ps1` handle the full integration workflow. Linux also has
the native Bash `up-linux.sh` for the core ERPNext site and
`install-apps-linux.sh` for the bundled custom apps; they need Docker Compose,
Python 3, and curl, but not PowerShell. They do not configure the planner,
Metabase, Node-RED, Shopify credentials, ngrok, or demo data.

## Services and dependencies

The Compose file defines seven containers. ngrok is a separately installed host
process, not a Compose service.

| Component | Image / build source | Published port | Dependencies and persistent data |
| --- | --- | --- | --- |
| `bench` (Frappe / ERPNext) | Local `comp_demo-bench:v16`, built from `bake/bench.Dockerfile` | host `${ERPNEXT_PORT:-8000}` → container `8000` | Depends on `db`, `redis-cache`, `redis-queue`; `bench_sites` volume and app source bind mounts |
| `db` (MariaDB) | `MARIADB` from `versions.env` | None; internal port `3306` | `db_data` named volume mounted at `/var/lib/mysql` |
| `redis-cache` | `REDIS` from `versions.env` | None; internal port `6379` | No named data volume |
| `redis-queue` | `REDIS` from `versions.env` | None; internal port `6379` | No named data volume |
| `node-red` | `NODE_RED` from `versions.env` | host `${NODE_RED_PORT:-1880}` → container `1880` | Depends on `bench`; `node_red_data` volume and flow-file bind mount |
| `scheduler` | Local `comp_demo-scheduler:latest`, built from `./scheduler` | host `${SCHEDULER_PORT:-3001}` → container `3000` | Depends on `bench` |
| `metabase` | `METABASE` from `versions.env` | host `${METABASE_PORT:-3005}` → container `3000` | Depends on `db`; stores its application metadata in the `metabase` database |

ngrok's API is available on host port `${NGROK_API_PORT:-4040}` when the host
ngrok process is running. It provides the public webhook tunnel; it is not
containerized or built by this repository.

## Database durability

MariaDB stores its data in the Compose named volume `db_data`, mounted at
`/var/lib/mysql`. The database survives container stops, container recreation,
Docker restarts, and `docker compose down` without `-v`. It is removed by
`docker compose down -v` or explicit volume deletion. A named volume is
persistent storage, not a backup; back up important data separately.

The bench site's files are stored separately in `bench_sites`. Redis data is
not persisted by named volumes in the current Compose definition.

**History:** an earlier setup used tmpfs because MariaDB table creation was
measured to be extremely slow on that host's container-storage path. The current
Compose configuration changed to `db_data` (the named-volume approach described
in `bake/README.md`, Track 2b). Initial population can still be slow on affected
hosts, but restarting no longer discards the database.

## Version references and app sources

| Component | Version / source in this repository |
| --- | --- |
| ERPNext and bundled Frappe bench | Base image: `ERPNEXT_BASE` in [`../versions.env`](../versions.env); local bench image tag `comp_demo-bench:v16` |
| MariaDB | `MARIADB` in [`../versions.env`](../versions.env) |
| Redis | `REDIS` in [`../versions.env`](../versions.env) for both Redis services |
| Metabase | `METABASE` in [`../versions.env`](../versions.env) |
| Node-RED | `NODE_RED` in [`../versions.env`](../versions.env) |
| Production planner | Built locally as `comp_demo-scheduler:latest` from `./scheduler` |
| Shopify Admin API | `${SHOPIFY_API_VERSION:-2026-04}`; API version, not app image version |

`versions.env` is the authoritative set of component image tags. The
`ERPNEXT_BASE` value is the build input; `docs/archive/ASSESSMENT-einvoicing-barcode.md`
records a different version from a live environment checked on 2026-11-04.
Treat that as historical runtime evidence, not the current build pin; verify a
running bench with `bench version`. Load both env files for direct Compose use:
`docker compose --env-file .env --env-file versions.env ...`.

The bench image includes the `barcode_shrdc`, `shopify`, and `eu_einvoice`
sources copied from `repos/` by `bake/bench.Dockerfile`. The Compose file also
bind-mounts `repos/item_tracking`, `repos/metabase_integration`, and
`repos/barcode-shrdc-v16-fixed` into the bench container. App source may change
independently of the base image tag; the repository's `repos/` trees are the
source used by this build.

The default site name, host ports, and other runtime settings are configurable
through `.env`; `.env.example` documents the supported defaults. The supported
`up.ps1` and `setup.ps1` entry points load both `.env` and `versions.env`. Direct
Compose commands must pass `--env-file .env --env-file versions.env`.
# Architecture and state map

What runs, where its state lives, and what a `docker compose down` actually
costs you. If you are about to run a destructive command, read the matrix first.

Compose project: `comp_demo` · site: `frontend` · host ports: 8000 (ERPNext),
3001 (planner), 1880 (Node-RED), 3005 (Metabase).

## Services

| Service | Image | Role | Depends on |
|---|---|---|---|
| `seed` | same image as `bench` | one-shot: restores `seed/frontend-database.sql.gz` into an empty volume, then exits 0. No-op (~2 s) when a site already exists | db (healthy); `bench` waits for it to complete |
| `bench` | `comp_demo-bench:v16` (built from `bake/bench.Dockerfile`) | ERPNext v16 + frappe + barcode_shrdc + shopify + eu_einvoice + render deps | db, redis-cache, redis-queue (healthy) |
| `db` | `mariadb:11.8` | site DB **and** Metabase metadata | – |
| `redis-cache` | `redis:6.2-alpine` | frappe cache | – |
| `redis-queue` | `redis:6.2-alpine` | background jobs | – |
| `node-red` | `nodered/node-red:5.0.9` (pinned in `versions.env`) | Shopify ↔ ERPNext bridge | bench (started) |
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
## How this is verified

| Layer | Command | Cost |
|---|---|---|
| Static (every push) | GitHub Actions `ci`: compose config, clean tree, no machine paths, PowerShell parse, shellcheck, python compile, image build, app-import smoke | ~4 min |
| Onboarding path (manual) | `tests/verify-clean-clone.ps1` - clones from GitHub into a disposable project (`comp_demo_verify`, shifted ports, own volumes), seeds, asserts, tears down | ~9 min |
| Full feature suite | `verify-all.ps1` against the live stack | ~5 min |

`tests/verify-clean-clone.ps1` is the one that matters before a release: it is
the only check that exercises `git clone` -> `docker compose` -> seeded site.
It found three bugs that every other layer passed (db host, deprecated
currentsite, missing logs dir).
## What a clone does and does not get

The per-capability table lives in `README.md` section 3b - keep it there, it is
the one people read first. Summary: core ERPNext, barcode, item tracking and the
seeded demo data work with no further steps; planner data endpoints, Shopify,
ngrok webhooks and Metabase dashboards each need credentials, and `setup.ps1`
covers the first three.

## Not part of the running stack

| Path | Status |
|---|---|
| `lowdefy/` | 19 files, ~89 KB, unreferenced by every launcher and by Compose. It is a Lowdefy prototype kept for reference; nothing in the demo starts it. Decide to delete or move to `docs/archive/` — until then, ignore it. |
| `sandbox/scripts/_legacy/` | 108 scripts quarantined on 2026-11-17 (proven unreferenced). Kept for one release cycle, then delete. |
