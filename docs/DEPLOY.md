# Clean-machine deployment (P7)

Everything below assumes **only Docker** is installed. No existing images, no
containers, no database volume, no manually copied app folders, and no files
from the original developer's machine are required.

The repository ships all eight applications' source (they are git-tracked under
`repos/`, 324 files). The bench image bakes them in at build time, and one
image-baked installer puts them on the site. There is no second, competing
installation path.

---

## 1. Prerequisites

| Requirement | Version | Check |
|---|---|---|
| Docker Engine + Compose v2 | Compose `2.20+`, Engine `24+` | `docker compose version` |
| Git | any | `git --version` |
| Disk | ~20 GB free (image + volumes) | — |
| RAM | 8 GB recommended (Metabase is capped at 3 GB) | — |

Linux/macOS: use `bash`, not `sh`. Windows: use **Git Bash** or WSL for the
`.sh` scripts, or the PowerShell launchers (`setup/up`) — the Docker artefacts are
identical either way.

Ports used by default: `8000` (ERPNext), `1880` (Node-RED), `3001` (planner),
`3005` (Metabase), `8088` (webhook sink). Change them in `.env` before starting.

## 2. Clone

```bash
git clone https://github.com/msf4-0/erpnext-v16-integrations-demo.git
cd erpnext-v16-integrations-demo
```

## 3. Configure

```bash
cp .env.example .env
chmod 600 .env
```

Open `.env` and replace the placeholder passwords (`DB_ROOT_PASSWORD`,
`ERPNEXT_ADMIN_PASSWORD`, `METABASE_*`). Values that are still `admin` /
`__FILL_ME__` are treated as demo defaults: the stack logs them, and refuses to
start when `ENVIRONMENT=production`. **Never commit `.env`** — it is gitignored.

`versions.env` pins every image. `ERPNEXT_BASE=frappe/erpnext:v16.35.0` is the
base for the bench image; change it only deliberately.

## 4. The setup command

```bash
./setup/$2
```

That is the whole deployment. In order, it:

1. validates `.env` and `versions.env`;
2. builds the bench image from `bake/bench.Dockerfile` (pulls the pinned
   `frappe/erpnext` base, copies **all six** custom apps from `repos/`,
   installs every app's Python dependencies, then *fails the build* if any app
   source is missing, is not a valid Frappe app, or cannot be imported);
3. starts `db`, `redis-cache`, `redis-queue` and the one-shot `seed` service;
4. `seed` restores the prepared demo site (`seed/frontend-database.sql.gz`)
   plus the Metabase metadata, so the demo data exists on first boot;
5. runs the canonical installer `/usr/local/bin/install-all-apps.sh`, which
   installs every missing app in dependency order, migrates once, and verifies
   both `list-apps` and module import;
6. waits for `/api/method/ping` and prints the installed app list.

Expected app list (order of installation):

```
frappe  erpnext  barcode_shrdc  shopify  eu_einvoice
item_tracking  metabase_integration  my_invois
```

First run takes roughly 20–40 minutes (image build dominates). Later starts take
seconds: the site already exists, so `seed` and the installer both exit early.

### The two first-time workflows — do not mix them

| Workflow | Command | What it does |
|---|---|---|
| **Restore demo data** (default) | `./setup/$2` or `docker compose up -d` | restores `seed/frontend-database.sql.gz`, then installs any app the dump predates |
| **From-scratch site** | `docker compose exec bench bash /tmp/comp-demo-bootstrap/provision-base.sh 16` | `bench new-site` + installs every app, **no demo data** |

Running both against the same `bench_sites` volume is not needed and not
supported: `seed` exits immediately when `sites/<site>/site_config.json`
already exists, so a restore never re-runs over a live site. To start over, use
a **new Compose project name and volumes** (never `down -v` on a live stack).

## 5. Access

* ERPNext: <http://localhost:8000> — user `Administrator`, password from `.env`.
* Planner: <http://localhost:3001>
* Node-RED: <http://localhost:1880>
* Metabase: <http://localhost:3005>
* Webhook sink: <http://localhost:8088/healthz>

## 6. Verify the eight apps

```bash
./sandbox/scripts/verify-deployment.sh
```

Read-only, seven checks: Compose config, bench/db containers, `bench version`,
all eight apps in `list-apps` installed exactly once, every app module
importable, `/api/method/ping` answering, and no `hooks.py`-referenced asset
missing. Equivalent manual commands:

```bash
docker compose exec -T bench bench --site frontend version
docker compose exec -T bench bench --site frontend list-apps
curl -H "Host: frontend" http://localhost:8000/api/method/ping
```

## 7. Stop / restart / persist

```bash
docker compose stop          # stop, keep containers and data
docker compose start         # start again (site intact, no reinstall)
docker compose restart bench # after config changes
docker compose down          # remove containers, KEEP volumes (db_data, bench_sites)
```

`db_data` (MariaDB) and `bench_sites` (site files, uploaded assets, config) are
named volumes, so a `down` + `up` cycle keeps all data. The seeder detects the
existing site and does nothing. **`docker compose down -v` deletes the demo.**
It is never part of any documented flow.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Build fails: `apps/<app>/<app>/hooks.py is missing` | `repos/` is incomplete (shallow export, partial clone, antivirus quarantine) | re-clone; `git status` must be clean; the guard fails loudly on purpose |
| Build fails during `pip install` | no network to PyPI | check connectivity, then re-run `docker compose build bench` (layers are cached) |
| Build fails in the import smoke test | an app's dependency did not install | read the `IMPORT FAILED:` line; it names the app and the module |
| `seed` exits 1: no site and no dump | `seed/frontend-database.sql.gz` missing (e.g. Git LFS not pulled) | `git lfs pull`, or provision from scratch (section 4) |
| `ERROR: install-all-apps finished INCOMPLETE` | an app failed to install | the failed names are printed; run `docker compose exec -T bench bash /usr/local/bin/install-all-apps.sh` for the full log |
| Site 500s with `(1045) Access denied` | container got a new bridge IP after restart | self-healing grant runs at every container start; `docker compose restart bench` re-runs it |
| `404 localhost does not exist` | no default site bound | `docker compose exec -T bench bench use frontend` |
| Desk reload-loops, `/assets/<app>/...js` 404 | asset symlink missing in `sites/assets` | recreated on every bench start; verify with `verify-deployment.sh` check 7 |
| Login fails after a restore | restored DB carries the old `db_password` | seeder aligns it; re-run `docker compose run --rm seed` |

Never "fix" a deployment by deleting volumes, reinstalling the site, or
replacing the bench image with one built on another machine.

## 9. Opting an app out

```bash
SKIP_APPS="my_invois" ./setup/$2
```

`my_invois` (Malaysia LHDN/MyInvois) and `eu_einvoice` install overlapping
e-invoice doctypes. Both are installed by default because the demo covers both;
on a site where they conflict, set `SKIP_APPS` in `.env`. The installer reports
skips explicitly — it never silently drops an app.
