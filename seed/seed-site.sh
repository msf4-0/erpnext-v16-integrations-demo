#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# seed-site.sh - create a working demo site WITHOUT running up.ps1.
#
# Runs as a one-shot compose service (`seed`) on a fresh clone. Three cases:
#
#   1. a site already exists            -> exit 0, do nothing (safe every boot)
#   2. seed/frontend-database.sql.gz     -> new-site + restore            (~5 min)
#      exists
#   3. no dump                          -> exit 1 with instructions
#
# Case 2 is the whole point: a clone gets the demo data (items, barcodes,
# company, planner work orders, demo user) in a fraction of the 25-35 minutes a
# full `up.ps1` provisioning run takes, because it never re-creates the 900
# tables one by one.
# ---------------------------------------------------------------------------
set -euo pipefail
cd /home/frappe/frappe-bench

SITE="${SITE_NAME:-frontend}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
SEED_DIR="/seed"
DUMP="${SEED_DIR}/frontend-database.sql.gz"

echo "== seed: site '${SITE}' =="

# --- case 1: already provisioned -------------------------------------------
if [ -f "sites/${SITE}/site_config.json" ]; then
    echo "seed: sites/${SITE} already exists - nothing to do"
    # The container's own startup block re-creates .pth/assets, so no work here.
    exit 0
fi

# --- case 3: nothing to restore from ---------------------------------------
if [ ! -f "${DUMP}" ]; then
    echo "seed: no site and no ${DUMP}."
    echo "      Run 'docker compose run --rm seed' after adding a dump, or run"
    echo "      up.ps1 to provision from scratch (~25-35 min)."
    exit 1
fi

if [ -d "sites/${SITE}" ]; then
    echo "seed: removing half-created sites/${SITE}"
    rm -rf "sites/${SITE}"
fi

# --- recreate the bench scaffolding a fresh bench_sites volume lacks -------
# `bench init` normally writes these; on a clone the volume is empty, and
# without them new-site talks to localhost:3306 instead of the db service.
# A fresh bench_sites volume has no logs/ directory. bench only creates it during
# `bench init`, so on a restored volume every python entrypoint dies with
#   FileNotFoundError: '/home/frappe/logs/database.log'
mkdir -p logs
mkdir -p frontend/logs
mkdir -p sites/assets
mkdir -p sites
if [ ! -f sites/apps.txt ]; then
    echo "seed: writing sites/apps.txt"
    printf 'frappe\nerpnext\nbarcode_shrdc\nshopify\neu_einvoice\nitem_tracking\nmetabase_integration\nmy_invois\n' > sites/apps.txt
fi

# --- db/redis endpoints in the GLOBAL config ---------------------------------
# The base image ships a sites/common_site_config.json containing only
# `default_site`, and Docker copies image content into a fresh named volume.
# The old guard ("write it only if the file is missing") therefore never fired
# on a clean clone, so every bench command in this container resolved
# db_host=localhost:3306 / redis://localhost:6379 and `bench migrate` aborted
# with "Service redis_cache is not running" - while the site itself kept serving
# without cache/queue. Merge the keys unconditionally instead of skipping.
echo "seed: ensuring db/redis keys in sites/common_site_config.json"
/home/frappe/frappe-bench/env/bin/python - <<'PY'
import json
import os

path = "/home/frappe/frappe-bench/sites/common_site_config.json"
cfg = {}
if os.path.exists(path):
    try:
        with open(path) as handle:
            cfg = json.load(handle) or {}
    except Exception:  # noqa: BLE001
        cfg = {}
cfg.update(
    {
        "db_host": "db",
        "db_port": 3306,
        "redis_cache": "redis://redis-cache:6379",
        "redis_queue": "redis://redis-queue:6379",
        "redis_socketio": "redis://redis-queue:6379",
        "socketio_port": 9000,
    }
)
with open(path, "w") as handle:
    json.dump(cfg, handle, indent=1)
print("seed: common_site_config ->", ", ".join(sorted(cfg)))
PY

# --- case 2: create the site record, then restore over it -------------------
# new-site is needed even though the dump contains everything: it creates the
# DB user + schema and writes site_config.json with credentials that the dump
# does not carry. The restore then replaces the empty schema's contents.
echo "seed: creating site record (this is the slow part, ~4-5 min)"
# --db-host/--db-port explicitly: the db service, never localhost. Do NOT use
# --no-mariadb-socket here - it pins db_host to 127.0.0.1 and new-site dies with
# "Can't connect to server on '127.0.0.1' (115)", because MariaDB is a service
# in this stack, not a socket inside this container.
bench new-site "${SITE}" \
    --db-host db \
    --db-port 3306 \
    --mariadb-root-password "${DB_ROOT_PASSWORD}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --force

# Bind the default site. Without this the bench answers
# `404 localhost does not exist` for every request, because Frappe resolves the
echo "seed: setting default site -> ${SITE}"
bench use "${SITE}"

echo "seed: restoring ${DUMP}"
bench --site "${SITE}" restore "${DUMP}" \
    --mariadb-root-password "${DB_ROOT_PASSWORD}" \
    --force

# The restored DB carries the previous site's db_password; align it with the
# fresh site_config.json so the running bench can actually log in.
echo "seed: migrating + clearing cache"
bench --site "${SITE}" migrate --skip-search-index || true
bench --site "${SITE}" clear-cache
bench --site "${SITE}" clear-website-cache || true

# --- all eight apps: install whatever the dump predates ---------------------
# The dump was taken at some earlier point in the demo's life, so it does not
# carry every app that is now in the image (historically it lacked my_invois;
# item_tracking / metabase_integration were mounted and installed by hand).
# Rather than special-casing one app per restore, run the SAME canonical
# installer the bench image ships. It is idempotent, ordered, and fails loudly
# if an app cannot be installed - a silently half-installed site is the bug
# this whole package exists to remove.
#   SKIP_APPS="my_invois" opts a conflicting LHDN layer out for one site.
echo "seed: installing all apps (idempotent; the dump covers most of them)"
INSTALLER=/usr/local/bin/install-all-apps.sh
if [ ! -x "${INSTALLER}" ]; then
    echo "seed: ERROR - ${INSTALLER} is missing from the bench image." >&2
    echo "      The image is older than P7; rebuild with: docker compose build bench" >&2
    exit 1
fi
SITE_NAME="${SITE}" bash "${INSTALLER}"

# Re-assert a host-agnostic grant: the restored dump's user was created bound to
# some old container IP, which is the classic post-restore 1045 failure.
DU=$(sed -n 's/.*"db_user"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "sites/${SITE}/site_config.json")
DP=$(sed -n 's/.*"db_password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "sites/${SITE}/site_config.json")
DN=$(sed -n 's/.*"db_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "sites/${SITE}/site_config.json")
if [ -n "${DU}" ] && [ -n "${DP}" ]; then
    MYSQL_PWD="${DB_ROOT_PASSWORD}" mariadb -h db -uroot -e "
        CREATE USER IF NOT EXISTS '${DU}'@'%' IDENTIFIED BY '${DP}';
        ALTER USER '${DU}'@'%' IDENTIFIED BY '${DP}';
        GRANT ALL PRIVILEGES ON \`${DN:-$DU}\`.* TO '${DU}'@'%';
        FLUSH PRIVILEGES;" || echo "seed: WARN could not re-assert grant for ${DU}"
fi

# --- self-check: a restore that silently produced an empty site is the exact
# failure this service exists to prevent, so fail loudly instead of letting the
# stack come up empty. bash quoting is clean here; doing this from PowerShell
# through docker exec is what made the earlier count unreliable.
ITEM_COUNT=$(bench --site "${SITE}" execute frappe.db.count --args "['Item']" 2>/dev/null | tail -1 | tr -d '[:space:]')
echo "seed: items after restore: ${ITEM_COUNT:-unknown}"
case "${ITEM_COUNT}" in
    ''|0) echo "seed: ERROR - restore produced no Item rows"; exit 1 ;;
esac

# --- Metabase metadata (dashboards + the ERPNext data source) --------------
# Metabase keeps its own metadata in the `metabase` schema, which a `bench
# backup` of the SITE does not contain. Without this, every clone gets a blank
# Metabase: no admin, no ERPNext data source, no "ERPNext Monitoring" dashboard.
MB_DUMP="/seed/metabase-db.sql.gz"
if [ -f "${MB_DUMP}" ]; then
    MB_TABLES=$(MYSQL_PWD="${DB_ROOT_PASSWORD}" mariadb -h db -uroot -N -B \
        -e "select count(*) from information_schema.tables where table_schema='metabase'" 2>/dev/null || echo 0)
    if [ "${MB_TABLES:-0}" = "0" ]; then
        echo "seed: restoring Metabase metadata (dashboards + ERPNext data source)"
        gunzip -c "${MB_DUMP}" | MYSQL_PWD="${DB_ROOT_PASSWORD}" mariadb -h db -uroot \
            || echo "seed: WARN Metabase restore failed - BI will start empty"
    else
        echo "seed: Metabase already initialised (${MB_TABLES} tables) - skipping"
    fi

    # A restored Metabase dump carries the previous site's database name and
    # its public dashboard UUID. Rebind the data source to the database that
    # this restore actually created, and persist the dashboard URL in the
    # site config so the /metabase page works immediately.
    echo "seed: binding Metabase data source to ${DN}"
    MYSQL_PWD="${DB_ROOT_PASSWORD}" mariadb -h db -uroot -e "
        CREATE USER IF NOT EXISTS 'metabase_user'@'%' IDENTIFIED BY 'metabase_demo_2026';
        ALTER USER 'metabase_user'@'%' IDENTIFIED BY 'metabase_demo_2026';
        GRANT SELECT, SHOW VIEW ON \`${DN}\`.* TO 'metabase_user'@'%';
        UPDATE metabase.metabase_database
           SET details = JSON_SET(details, '$.dbname', '${DN}', '$.host', 'db',
                                  '$.port', 3306, '$.user', 'metabase_user',
                                  '$.password', 'metabase_demo_2026')
         WHERE name = 'ERPNext';
        FLUSH PRIVILEGES;" || echo "seed: WARN could not rebind Metabase data source"

    MB_UUID=$(MYSQL_PWD="${DB_ROOT_PASSWORD}" mariadb -h db -uroot -N -B \
        -e "select public_uuid from metabase.report_dashboard where id=2 and public_uuid is not null limit 1" 2>/dev/null || true)
    if [ -n "${MB_UUID:-}" ]; then
        /home/frappe/frappe-bench/env/bin/python - "$SITE" "$MB_UUID" <<'PY'
import json
import sys

site, uuid = sys.argv[1], sys.argv[2]
path = f"/home/frappe/frappe-bench/sites/{site}/site_config.json"
with open(path) as handle:
    cfg = json.load(handle)
cfg["metabase_dashboard_url"] = f"http://localhost:3005/public/dashboard/{uuid}"
with open(path, "w") as handle:
    json.dump(cfg, handle, indent=1)
print(f"seed: metabase_dashboard_url -> {cfg['metabase_dashboard_url']}")
PY
    fi
fi

echo "seed: done - site '${SITE}' restored"
