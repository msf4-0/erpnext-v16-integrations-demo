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

Linux / macOS / WSL / Git Bash:

```bash
bash ./setup/up-linux.sh
```

`COMPOSE_PROJECT_NAME` in `.env` selects the Compose project (default
`comp_demo`), and `BENCH_IMAGE` selects the image tag. **On a machine that
already runs the live demo, set both to fresh values** (plus the four ports):
the default project name is the live one. On Git Bash/Cygwin the launcher
disables MSYS path conversion itself, so in-container paths are not rewritten
into `C:/…`.

Windows (PowerShell, native — no Git Bash needed):

```powershell
powershell -ExecutionPolicy Bypass -File .\setup\up.ps1
```

Both run the same compose project and produce the same stack; the PowerShell
launcher is not a wrapper around the shell script, it is the Windows path.

That is the whole deployment. In order, it:

1. validates `.env` and `versions.env`;
2. builds the bench image from `bake/bench.Dockerfile` (pulls the pinned
   `frappe/erpnext` base, copies **all five** custom apps from `repos/`,
   installs every app's Python dependencies, then *fails the build* if any app
   source is missing, is not a valid Frappe app, or cannot be imported);
3. starts `db`, `redis-cache`, `redis-queue` and the one-shot `seed` service,
   then `bench`, `metabase`, `node-red`, `scheduler` and `webhook-sink` (so
   every endpoint in §5 is live after the one command);
4. `seed` restores the prepared demo site (`seed/frontend-database.sql.gz`)
   plus the Metabase metadata, so the demo data exists on first boot;
5. runs the canonical installer `/usr/local/bin/install-all-apps.sh`, which
   installs every missing app in dependency order, migrates once, and verifies
   both `list-apps` and module import;
6. waits for `/api/method/ping` and prints the installed app list.

Expected app list (order of installation):

```
frappe  erpnext  barcode_shrdc  shopify
item_tracking  metabase_integration  my_invois
```

`eu_einvoice` (EU e-invoicing) is **not** part of the default build. The demo's
e-invoicing story is Malaysia LHDN / MyInvois via `my_invois`. The EU source is
still vendored under `repos/eu_einvoice` for reference; it is not copied into the
image and not installed.

### What the demo data is

A deliberately small go-kart dataset, created by
`sandbox/scripts/seed-gokart-demo.py` (and baked into
`seed/frontend-database.sql.gz`, which is what a normal clone restores):

| Item | Rate (selling) | Notes |
|---|---|---|
| `GO-KART` | 4500 | assembled go-kart, has a BOM |
| `FRM-001` Frame | 1800 | **serial-tracked**, `FRM-001-0001…0068` |
| `WHL-001` Wheel | 220 | 4 per kart |
| `STR-001` Steering Wheel | 310 | 1 per kart |
| `SEAT-001` Seat | 260 | 1 per kart |

The BOM is `GO-KART = 1 × Frame + 4 × Wheel + 1 × Steering Wheel + 1 × Seat`.
Standard Selling prices exist for all five items; Standard Buying prices exist
for the parts.

First run takes roughly 20–40 minutes (image build dominates). Later starts take
seconds: the site already exists, so `seed` and the installer both exit early.

### Where the bench image comes from

**A local build is the default and the supported path.** The bench image is not
published to a public registry: the GHCR package is private to the company, so a
clone on someone else's machine cannot pull it.

`setup/pull-bench.ps1` therefore does not invent a remote: with no
`BENCH_IMAGE` namespaced ref, no `BENCH_PULL_GHCR=1` and no `BENCH_BUNDLE_URL`
it reports that a build is required and exits, and the stack builds
`bake/bench.Dockerfile` locally (25–40 min, once).

If you *do* have somewhere to host the ~3 GB image (an internal registry, an SMB
share, a `docker save` tarball), two opt-ins exist:

```bash
BENCH_IMAGE=registry.internal/comp-demo-bench:v16   # a ref Docker can already pull
BENCH_PULL_GHCR=1                                   # try the company GHCR anyway
BENCH_BUNDLE_URL=https://internal/comp-demo-bench-v16-amd64.tar.gz
```

Nothing in the default flow depends on any of them.

### The two first-time workflows — do not mix them

| Workflow | Command | What it does |
|---|---|---|
| **Restore demo data** (default) | `bash ./setup/up-linux.sh` (Windows: `.\setup\up.ps1`) | restores `seed/frontend-database.sql.gz`, then installs any app the dump predates |
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

## 6. Verify the seven apps

```bash
./sandbox/scripts/verify-deployment.sh
```

Read-only, seven checks: Compose config, bench/db containers, `bench version`,
all seven apps installed exactly once **as recorded in the database**
(`frappe.get_installed_apps` / `tabInstalled Application`), every app module
importable, `/api/method/ping` answering, and no `hooks.py`-referenced asset
missing.

**Do not** judge installation from `bench --site frontend list-apps`: on this
bench build it under-reports and can print only `frappe`/`erpnext` for a fully
installed site. The verifier prints it for information only. The script takes
**no** positional arguments — select the target with environment variables:

```bash
PROJECT=comp_demo_cold ERPNEXT_PORT=18001 SITE_NAME=frontend \
  bash ./sandbox/scripts/verify-deployment.sh
```

An unknown argument now aborts with exit code 2 instead of silently verifying
the default project.

Equivalent manual commands:

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
SKIP_APPS="my_invois" bash ./setup/up-linux.sh
```

`my_invois` (Malaysia LHDN/MyInvois) is the only e-invoicing app in the default
build. The EU app (`eu_einvoice`) was removed from the build; its source stays
under `repos/eu_einvoice` for reference only (see §4).

`my_invois` registers **no** `doc_events`. It ships Custom Fields and a Sales
Invoice Client Script via `fixtures`, so it adds UI actions only — it cannot
block a save. The installer reports skips explicitly; it never silently drops
an app.

## 10. Windows notes

`setup/up.ps1` is the native Windows path and needs no Git Bash. Three things on
this host are not obvious and cost real debugging time:

**`docker compose up -d` can hang.** Docker Desktop attaches agent hooks to the
`compose up` subcommand and the hook never returns; the containers are left in
`Created`. The launcher therefore splits the two steps:

```powershell
docker compose -p comp_demo --env-file .env --env-file versions.env -f docker-compose.yml create
docker start comp_demo-db-1 comp_demo-redis-cache-1 comp_demo-redis-queue-1 comp_demo-bench-1
```

`create` returns, `docker start` takes ~15 s. Use that pair instead of `up -d`.

**Git Bash is still needed for the `.sh` tooling.** The `.sh` scripts and
`verify-deployment.sh` assume bash: `C:\Program Files\Git\bin\bash.exe` works.
PowerShell one-liners that nest quoting around these scripts fail on this host —
write the command to a `.ps1`/`.sh` file in `%TEMP%` and run the file.

**Never point the launcher at a project that holds a live demo.** Step 3 runs
`compose down --remove-orphans` for the target project. Run an isolated check
with its own project name, ports and image tag:

```powershell
# .env.p8test: ERPNEXT_PORT=18003, NODE_RED_PORT=11880, SCHEDULER_PORT=13001,
#              METABASE_PORT=13005, WEBHOOK_SINK_PORT=18088,
#              BENCH_IMAGE=comp_demo-bench:p8-test
powershell -ExecutionPolicy Bypass -File .\setup\up.ps1 `
  -Project comp_demo_p8 -EnvFile .env.p8test -SkipScheduler
```

`BENCH_IMAGE` selects the bench image, so a test run never overwrites the tag the
live demo uses. `-SkipScheduler` leaves the standalone planner alone.
