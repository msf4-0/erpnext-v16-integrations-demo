# FACTS — the single source of truth

Every number below was **measured on the running stack on 2026-11-17**. If another document in this
repository disagrees, that document is wrong and should be corrected or deleted — do not "average"
the two. Regenerate with the commands in the last section.

## Versions

| Component | Value | How it was measured |
|---|---|---|
| Frappe | **16.35.0** | `bench --site frontend version` |
| ERPNext | **16.35.0** | `bench --site frontend version` |
| MariaDB | **11.8** | `versions.env`, `docker ps` |
| Redis (cache + queue) | **6.2-alpine** | `versions.env`, `docker ps` |
| Metabase | **v0.58.38.2** | `docker ps` |
| Node-RED | **5.0.9** (pinned in `versions.env`; running container matches) | `docker ps`, `node-red --version` |
| Bench image | **`comp_demo-bench:v16-live`** (= `6e4bb0e551ea`) | `docker inspect comp_demo-bench-1` |
| Planner image | `comp_demo-scheduler:latest` | `docker ps` |
| Webhook sink image | `python:3.12-alpine` | `docker ps` |

> `comp_demo-bench:v16` also exists locally but contains **5 apps**, not 8 — it is missing
> `item_tracking`, `metabase_integration` and `my_invois`. Never recreate the container onto it.
> `.env` pins `BENCH_IMAGE=comp_demo-bench:v16-live` for exactly this reason.

## Services — **9** in compose, 8 running

`bench`, `seed` (one-shot, exits after restoring the demo DB), `db`, `redis-cache`, `redis-queue`,
`node-red`, `scheduler`, `metabase`, `webhook-sink`.

## Ports (host)

| Service | Port |
|---|---|
| ERPNext UI/API | **8000** |
| Planner (container listens on 3000) | **3001** |
| Node-RED | **1880** |
| Metabase | **3005** |
| Webhook sink | **8088** |
| ngrok agent API | **4040** — *not* 4041 |

## Site, credentials, routes

- Site name: **`frontend`**; admin user `Administrator`; password comes from `ERPNEXT_ADMIN_PASSWORD`
  in `.env` (not reproduced here).
- Health probe: `GET http://localhost:8000/api/method/ping` → `{"message":"pong"}`.
- Metabase embed route: **`/metabase`** (`repos/metabase_integration/metabase_integration/www/metabase.py`).

## Installed apps — 8

| App | Version | Source |
|---|---|---|
| frappe | 16.35.0 | image |
| erpnext | 16.35.0 | image |
| barcode_shrdc | 0.0.2 | bind mount (`repos/barcode-shrdc-v16-fixed`) |
| shopify | 0.0.1 | image (`bake/bench.Dockerfile`) |
| eu_einvoice | 16.3.0 | image (`bake/bench.Dockerfile`) |
| item_tracking | 0.0.2 | bind mount |
| metabase_integration | 0.0.1 | bind mount |
| **my_invois** | **0.0.1** | **bind mount, and installed** |

`repos/my_invois` exists, is mounted at `apps/my_invois`, and `bench list-apps` reports it
installed. Its fixtures were never synced — that is a data-completeness gap, not an absence of the
app.

## Bench container mounts

`bench_sites` volume → `/home/frappe/frappe-bench/sites`; `logs`; and four app bind mounts:
`repos/barcode-shrdc-v16-fixed`, `repos/item_tracking`, `repos/metabase_integration`,
`repos/my_invois`. So `apps/` **is** partly a bind mount.

## Persistence

- Site DB: durable **`db_data`** named volume (not tmpfs; `DB_TMPFS_SIZE` is legacy but still read).
- Site files: **`bench_sites`** volume.
- Background jobs: `bench schedule` + `bench worker --queue short,default,long` run inside the bench
  container (compose ~141-143) — they already exist; do not "add workers".

## Launchers — one per platform

| Platform | First command | Notes |
|---|---|---|
| Windows | `powershell -ExecutionPolicy Bypass -File .\up.ps1` | `start.ps1` wraps pull → seed → start → wire; `setup.ps1` is convergence/verification (`-VerifyOnly`) |
| Linux | `bash ./up-linux.sh` then `bash ./install-apps-linux.sh` | `up-linux.sh` deliberately uses `docker compose up -d`; on Windows that can hang |
| Either | — | There is no `sandbox/up.ps1` any more; it was deleted 2026-11-17 |

## Regenerate the measurements

```bash
docker compose -p comp_demo --env-file .env --env-file versions.env -f docker-compose.yml config --services
docker ps --format '{{.Names}} {{.Image}}'
docker exec comp_demo-bench-1 bash -lc "cd /home/frappe/frappe-bench && bench --site frontend version"
grep -E '^(ERPNEXT_PORT|SCHEDULER_PORT|NODE_RED_PORT|METABASE_PORT|WEBHOOK_SINK_PORT|NGROK_API_PORT)=' .env
```

## Upstream sources

Verified upstreams for the apps that have one. `item_tracking`, `metabase_integration`,
`my_invois` and `scheduler/` are first-party (no upstream).

| App | Verified upstream URL |
|---|---|
| `barcode_shrdc` | <https://github.com/msf4-0/ERPNext-Barcode-Integration> |
| `shopify` | <https://github.com/msf4-0/shopify-ERPnext> |
| `eu_einvoice` | <https://github.com/alyf-de/eu_einvoice> |
