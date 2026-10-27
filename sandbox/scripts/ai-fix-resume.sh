#!/usr/bin/env bash
# ai-fix-resume.sh — finish the ERPNEXT-AI-FIX bring-up inside an
# already-`bench init`-ed bench, logging every step to /tmp/ai-fix-resume.log.
#
# Written as a FILE (not an inline `docker exec ... bash -lc "..."` command)
# because this host's PowerShell/Windows quoting mangles nested bash badly.
#
# Run inside the bench container as the `frappe` user:
#   bash /tmp/scripts/ai-fix-resume.sh
set -uo pipefail

SITE="${SITE_NAME:-frontend}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-admin}"
BENCH="/home/frappe/frappe-bench"
LOG=/tmp/ai-fix-resume.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

say() { echo; echo "[$(date +%H:%M:%S)] ===== $* ====="; }

cd "$BENCH" || { echo "ERROR: $BENCH missing"; exit 1; }
say "resume start (site=$SITE)"

# ---------------------------------------------------------------------------
# 1. bench CLI health
# ---------------------------------------------------------------------------
say "bench CLI check"
if timeout 60 bench --version; then
  echo "bench CLI ok"
else
  echo "WARNING: bench --version did not return within 60s"
fi

# ---------------------------------------------------------------------------
# 2. global config, written directly
# ---------------------------------------------------------------------------
# `bench set-config -g` hangs on this host (it blocks after writing the file).
# The file is plain JSON, so write it with the bench venv python instead.
say "global config"
env/bin/python - "$SITE" <<'PYEOF'
import json
import sys

path = "sites/common_site_config.json"
conf = json.load(open(path))
conf.update(
    {
        "db_host": "db",
        "db_port": 3306,
        "redis_cache": "redis://redis-cache:6379",
        "redis_queue": "redis://redis-queue:6379",
        "default_site": sys.argv[1],
        "serve_default_site": True,
    }
)
json.dump(conf, open(path, "w"), indent=1, sort_keys=True)
print("db_host=%s db_port=%s redis_cache=%s default_site=%s" % (
    conf["db_host"], conf["db_port"], conf["redis_cache"], conf["default_site"]))
PYEOF

# ---------------------------------------------------------------------------
# 3. site creation
# ---------------------------------------------------------------------------
say "create site $SITE"
if [ -d "sites/$SITE" ]; then
  echo "-- removing stale site dir (its database was wiped with the tmpfs reset)"
  rm -rf "sites/$SITE"
fi

if bench new-site --help 2>&1 | grep -q -- --mariadb-root-password; then
  ROOT_PW_FLAG="--mariadb-root-password"; ROOT_USER_FLAG="--mariadb-root-username"
else
  ROOT_PW_FLAG="--db-root-password"; ROOT_USER_FLAG="--db-root-username"
fi

NEWSITE_OK=0
bench new-site "$SITE" --admin-password admin \
    "$ROOT_PW_FLAG" "$DB_ROOT_PASSWORD" "$ROOT_USER_FLAG" root \
    --install-app erpnext && NEWSITE_OK=1
if [ "$NEWSITE_OK" -ne 1 ]; then
  echo "-- new-site failed; retrying with --force"
  bench new-site "$SITE" --force --admin-password admin \
      "$ROOT_PW_FLAG" "$DB_ROOT_PASSWORD" "$ROOT_USER_FLAG" root \
      --install-app erpnext && NEWSITE_OK=1
fi
if [ "$NEWSITE_OK" -ne 1 ]; then
  echo "FATAL: could not create the site"
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. restart serve
# ---------------------------------------------------------------------------
say "restart bench serve"
pkill -f 'frappe serve' 2>/dev/null
pkill -f 'bench serve' 2>/dev/null
sleep 3
( cd "$BENCH" && setsid nohup bench serve --port 8000 > /tmp/bench-serve.log 2>&1 < /dev/null & disown )
SERVED=0
for _ in $(seq 1 90); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SITE" http://localhost:8000/api/method/ping || true)
  [ "$code" = "200" ] && { SERVED=1; echo "serve up (ping 200)"; break; }
  sleep 2
done
[ "$SERVED" -eq 1 ] || { echo "WARNING: serve did not answer 200"; }

# ---------------------------------------------------------------------------
# 5. barcode_shrdc + shopify
# ---------------------------------------------------------------------------
say "install apps"
if [ -f /tmp/scripts/ai-fix-install.sh ]; then
  bash /tmp/scripts/ai-fix-install.sh
else
  echo "WARNING: /tmp/scripts/ai-fix-install.sh missing"
fi

# ---------------------------------------------------------------------------
# 6. summary
# ---------------------------------------------------------------------------
say "summary"
bench --site "$SITE" list-apps
bench version
echo "ping=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SITE" http://localhost:8000/api/method/ping)"
say "resume done"
