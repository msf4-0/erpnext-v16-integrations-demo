#!/usr/bin/env bash
# ai-fix-provision-site.sh — create the ERPNext site inside an ALREADY
# `bench init`-ed bench.
#
# Why this exists instead of provision-base.sh: provision-base.sh runs
# `bench get-app erpnext` unconditionally and aborts when apps/erpnext already
# exists. On a resume (bench already initialised, apps already cloned - the
# expensive part) that would needlessly re-clone. This script does only the
# site half, and it also clears a stale `sites/<site>` directory, whose
# site_config.json holds credentials for a database that may have been wiped
# (the DB datadir is tmpfs - see the compose file).
#
# Run inside the bench container as the `frappe` user:
#   bash /tmp/scripts/ai-fix-provision-site.sh
set -uo pipefail

SITE="${SITE_NAME:-frontend}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-admin}"
BENCH="/home/frappe/frappe-bench"
cd "$BENCH" || { echo "ERROR: $BENCH missing"; exit 1; }

if [ ! -d apps/erpnext ]; then
  echo "ERROR: apps/erpnext is missing - run provision-base.sh instead"
  exit 1
fi

echo "== global config =="
bench set-config -g db_host db
bench set-config -g db_port 3306
bench set-config -g redis_cache redis://redis-cache:6379
bench set-config -g redis_queue redis://redis-queue:6379

# A stale site directory carries db_name/db_password for a database that no
# longer exists, which makes `bench new-site` fail in confusing ways.
if [ -d "sites/$SITE" ]; then
  echo "-- removing stale site dir sites/$SITE (its database no longer exists)"
  rm -rf "sites/$SITE"
fi

if bench new-site --help 2>&1 | grep -q -- --mariadb-root-password; then
  ROOT_PW_FLAG="--mariadb-root-password"
  ROOT_USER_FLAG="--mariadb-root-username"
else
  ROOT_PW_FLAG="--db-root-password"
  ROOT_USER_FLAG="--db-root-username"
fi

echo "== bench new-site $SITE (with erpnext) =="
if ! bench new-site "$SITE" --admin-password admin \
      "$ROOT_PW_FLAG" "$DB_ROOT_PASSWORD" "$ROOT_USER_FLAG" root --install-app erpnext; then
  echo "-- new-site failed; retrying with --force --"
  bench new-site "$SITE" --force --admin-password admin \
      "$ROOT_PW_FLAG" "$DB_ROOT_PASSWORD" "$ROOT_USER_FLAG" root --install-app erpnext || exit 1
fi

bench set-config -g default_site "$SITE"

echo "== restart bench serve =="
pkill -f 'frappe serve' 2>/dev/null
pkill -f 'bench serve' 2>/dev/null
sleep 3
( cd "$BENCH" && setsid nohup bench serve --port 8000 > /tmp/bench-serve.log 2>&1 < /dev/null & disown )
for _ in $(seq 1 90); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SITE" http://localhost:8000/api/method/ping || true)
  [ "$code" = "200" ] && { echo "-- serve up (ping 200)"; break; }
  sleep 2
done

echo "== result =="
bench --site "$SITE" list-apps
bench version
echo "ping=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SITE" http://localhost:8000/api/method/ping)"
