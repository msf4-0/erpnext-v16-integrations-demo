# Manual Linux setup — comp_demo (no scripts)

Everything below is plain Docker/Compose and `bench` CLI. No `.ps1`, no `.sh`.

---

## Why `sudo docker compose up` does not work

| Cause | What you see |
|---|---|
| `versions.env` is never loaded, but the compose file hard-requires it: `${ERPNEXT_BASE:?}`, `${MARIADB:?}`, `${NODE_RED:?}`, `${METABASE:?}` | `required variable ERPNEXT_BASE is missing a value: Load versions.env before starting Compose` |
| The bench image `comp_demo-bench:v16` is not on Docker Hub; the `ghcr.io/msf4-0/...` package is private | `pull access denied for comp_demo-bench` / `manifest unknown` |
| The `seed` one-shot service uses the same image | same pull error, and `bench` waits on it forever |
| The image's own `CMD` is `sleep infinity`; the real bootstrap lives in the compose `command:` block | a bench container that starts but serves nothing |

So three things are mandatory: **two `--env-file`s**, a **locally built image**, and **not overriding `command:`**.

---

## 0. Prerequisites

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 git curl
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"      # then log out / log in
docker compose version               # v2.x
docker info                          # daemon reachable
```

Disk: ~15–20 GB free. RAM: 8 GB comfortable (Metabase alone is capped at 3 GB).

## 1. Configure `.env`

```bash
cd /path/to/erpnextcomp_demo
cp .env.example .env
chmod 600 .env
```

Edit `.env`, minimum:

```ini
COMPOSE_PROJECT_NAME=comp_demo
ENVIRONMENT=development
SITE_NAME=frontend
ERPNEXT_PORT=8000
DB_ROOT_PASSWORD=<pick one>
ERPNEXT_ADMIN_PASSWORD=<pick one>
# leave SHOPIFY_*, NGROK_*, NODE_RED_SOURCE_FLOW blank
# leave BENCH_IMAGE unset -> uses comp_demo-bench:v16
```

Leave `BENCH_IMAGE` empty so it resolves to the tag you build in step 2.

## 2. Build the bench image (once, ~10–25 min)

```bash
cd /path/to/erpnextcomp_demo
docker build -f bake/bench.Dockerfile \
  --build-arg ERPNEXT_BASE=frappe/erpnext:v16.35.0 \
  -t comp_demo-bench:v16 .
```

The tag **must** be `comp_demo-bench:v16` (`docker-compose.yml` line 33 default).

Check:

```bash
docker image inspect comp_demo-bench:v16 --format '{{.Size}}'
```

## 3. Bring up MariaDB + Redis

Define one shell variable so every command carries the same flags (the
`--env-file` pair is the part everybody forgets):

```bash
cd /path/to/erpnextcomp_demo
COMPOSE="docker compose -p comp_demo --env-file .env --env-file versions.env -f docker-compose.yml"
```

```bash
$COMPOSE up -d db redis-cache redis-queue
$COMPOSE ps
```

Wait for MariaDB to answer (same probe the healthcheck uses):

```bash
$COMPOSE exec -T db sh -lc \
  'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb-admin ping -h 127.0.0.1 -uroot'
```

## 4. Create the site from the demo dump

The `seed` service restores `seed/frontend-database.sql.gz` (items, barcodes,
company, planner work orders, the 4 custom apps) and is a no-op once
`sites/frontend` exists.

```bash
$COMPOSE run --rm seed
```

Takes ~5 min the first time. Success looks like:

```
seed: items after restore: <non-zero>
seed: done - site 'frontend' restored
```

If you see `seed: ERROR - restore produced no Item rows`, stop and check
`$COMPOSE logs db` before continuing.

## 5. Start the bench

```bash
$COMPOSE up -d bench
$COMPOSE logs -f bench
```

Expected lines in the log:

```
startup policy: ...
db-grant: re-asserted <db_user>@%
```

Nothing that says `asset-check: MISSING ...`. `Ctrl-C` leaves the container
running (it is detached).

The compose `command:` starts `bench serve` **plus** `bench schedule` and
`bench worker` — do not run those by hand.

## 6. Verify

```bash
curl -sS -H 'Host: frontend' http://localhost:8000/api/method/ping
$COMPOSE exec bench bench --site frontend list-apps
```

Browser: <http://localhost:8000> — site `frontend`, login `Administrator`
with the password baked into the dump (the demo default is `admin`;
`ERPNEXT_ADMIN_PASSWORD`/`ADMIN_PASSWORD` in `.env` only affect the throwaway
site that `bench new-site` makes *before* the restore overwrites auth).

`list-apps` should show `frappe`, `erpnext`, `barcode_shrdc`, `shopify`,
`eu_einvoice`, `item_tracking`, `metabase_integration`, `my_invois`. The dump
already predates only `my_invois`, which the seeder installs itself.

### Install an app only if it is missing

Per app, one at a time (`shopify` in the example):

```bash
# 1. register the app name (trailing-newline safe)
$COMPOSE exec bench bash -lc 'cd /home/frappe/frappe-bench && f=sites/apps.txt; \
  [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ] && echo >> "$f"; \
  grep -qx shopify "$f" || echo shopify >> "$f"'

# 2. put it on the venv import path (bind-mounted apps need this after a recreate)
$COMPOSE exec bench bash -lc 'cd /home/frappe/frappe-bench && \
  for sp in env/lib/python*/site-packages; do \
    echo /home/frappe/frappe-bench/apps/shopify > "$sp/shopify.pth"; done'

# 3. install + migrate
$COMPOSE exec bench bash -lc 'cd /home/frappe/frappe-bench && \
  bench --site frontend install-app shopify && bench --site frontend migrate'
```

Bind-mounted sources: `barcode_shrdc`, `item_tracking`, `metabase_integration`,
`my_invois` (paths in `docker-compose.yml` lines 146–163). `shopify` and
`eu_einvoice` are baked into the image.

### Rebuild front-end assets (only if you changed app code)

```bash
$COMPOSE exec bench bash -lc 'export PATH="$(ls -d /home/frappe/.nvm/versions/node/*/bin | tail -1):$PATH"; \
  cd /home/frappe/frappe-bench && bench build'
$COMPOSE restart bench
```

### Barcode → PNG/PDF dependencies (root, runtime layer)

Already in `comp_demo-bench:v16`; only needed if you built a different base:

```bash
$COMPOSE exec -u root bench bash -lc \
  'apt-get update -qq && apt-get install -y -qq libcairo2-dev pkg-config build-essential'
$COMPOSE exec bench bash -lc 'cd /home/frappe/frappe-bench && \
  ./env/bin/pip install -q reportlab rlPyCairo qrcode pillow && \
  ./env/bin/python -c "import reportlab, rlPyCairo; print(\"render deps OK\")"'
```

These live in the container layer — re-run after any image rebuild.

## 7. Optional services

```bash
# production planner (port 3001) + tunnel-free webhook receiver (port 8088)
$COMPOSE up -d --build scheduler webhook-sink

# Node-RED Shopify bridge (1880) and Metabase BI (3005)
$COMPOSE up -d node-red metabase
```

* Planner calls ERPNext with `SCHEDULER_ERPNEXT_API_KEY/SECRET`; the UI loads
  without them, API calls 401 until you mint a token pair and put it in `.env`,
  then `$COMPOSE up -d scheduler` again.
* Metabase is seeded by the `seed` service (`admin@demo.local` /
  `compdemo2026`, port 3005).
* Node-RED without `SANDBOX`/Shopify creds starts but its Shopify nodes idle.
* `ngrok` is deliberately not a container — skip it unless you need Shopify
  webhooks from the internet.

## 8. Full site creation without the dump (fresh, empty ERPNext)

Use this only if you do not want demo data.

```bash
$COMPOSE exec bench bash -lc 'cd /home/frappe/frappe-bench && \
  bench set-config -g db_host db && \
  bench set-config -g db_port 3306 && \
  bench set-config -g redis_cache redis://redis-cache:6379 && \
  bench set-config -g redis_queue redis://redis-queue:6379'

$COMPOSE exec bench bash -lc 'cd /home/frappe/frappe-bench && \
  bench new-site frontend --db-host db --db-port 3306 \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ERPNEXT_ADMIN_PASSWORD" \
    --install-app erpnext'

$COMPOSE exec bench bash -lc 'cd /home/frappe/frappe-bench && bench use frontend'
```

Then install the custom apps with the three commands from step 6. `set-config -g`
writes `sites/common_site_config.json`, which is why `db_host` must be the
service name `db`, never `127.0.0.1`.

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `required variable ERPNEXT_BASE is missing a value` | you dropped `--env-file versions.env` |
| `pull access denied for comp_demo-bench` | step 2 not done, or tagged with a different name |
| `(1045) Access denied for user '...'@'172.x.x.x'` | bridge IP changed; restart `bench` — its startup block re-asserts the `'%'` grant. If you bypassed it: `$COMPOSE exec -T db sh -lc 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot -e "SELECT user,host FROM mysql.user"'` |
| `404 localhost does not exist` | no default site: `$COMPOSE exec bench bench --site frontend list-apps`, then `$COMPOSE exec bench bench use frontend`; the container also needs a restart to reload `default_site` |
| Desk page reloads in a loop | `asset-check: MISSING /assets/...` in `$COMPOSE logs bench` — the referenced bundle was never built; run `bench build` (step 6) |
| `ModuleNotFoundError: No module named '<app>'` | `.pth` was lost on container recreate; re-run step 6.2 and `$COMPOSE restart bench` |
| `bin/sh: node: not found` during `bench build` | node is under `~/.nvm`; export the PATH as shown in step 6 |
| `Permission denied` reading `./repos` on Fedora/RHEL | SELinux blocks the bind mount; `sudo chcon -Rt svirt_sandbox_file_t /path/to/erpnextcomp_demo` (or add `:z` to those volumes) |
| Everything `root`-owned after `sudo` docker | `$COMPOSE exec -u root bench chown -R frappe:frappe /home/frappe/frappe-bench/sites` |

Remember: `$COMPOSE exec` runs as **`frappe`** by default — correct. Use
`-u root` only for `apt-get`.

## 10. Stop / reset

```bash
$COMPOSE stop                 # keep data
$COMPOSE down                 # remove containers, keep db_data + bench_sites
$COMPOSE down -v              # DESTRUCTIVE: drops the site DB and bench tree
```
