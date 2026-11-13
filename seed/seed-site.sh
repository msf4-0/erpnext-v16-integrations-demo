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
mkdir -p sites
if [ ! -f sites/common_site_config.json ]; then
    echo "seed: writing sites/common_site_config.json"
    cat > sites/common_site_config.json <<JSON
{
  "db_host": "db",
  "db_port": 3306,
  "redis_cache": "redis://redis-cache:6379",
  "redis_queue": "redis://redis-queue:6379",
  "redis_socketio": "redis://redis-queue:6379",
  "socketio_port": 9000
}
JSON
fi
if [ ! -f sites/apps.txt ]; then
    echo "seed: writing sites/apps.txt"
    printf 'frappe\nerpnext\nbarcode_shrdc\nshopify\neu_einvoice\nitem_tracking\nmetabase_integration\n' > sites/apps.txt
fi
printf '%s\n' "${SITE}" > sites/currentsite.txt

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

echo "seed: done - site '${SITE}' restored"
