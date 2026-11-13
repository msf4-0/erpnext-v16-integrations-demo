# comp_demo architecture

> **Authoritative reference:** this document is the source of truth for the
> Compose topology, published ports, image versions, app sources, and database
> durability. Other documentation may give operational summaries, but must not
> contradict this reference or the Compose configuration.

## Scope and canonical location

The project is the repository root, with Docker Compose project name `comp_demo`
and ERPNext site `frontend` by default. Run commands from the repository root;
paths in this document are repository-relative. `docker-compose.yml` is the
authoritative definition of the container stack. `up.ps1` and `setup.ps1` are
the supported Windows PowerShell entry points.

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
`ERPNEXT_BASE` value is the build input; `docs/ASSESSMENT-einvoicing-barcode.md`
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
