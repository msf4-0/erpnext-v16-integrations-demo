#!/usr/bin/env bash
# rebuild-apps.sh — container-side: install/reinstall the whole app set on an
# already-provisioned base, in the correct order, idempotently.
#
# This is the container half of the one-command rebuild. The host half
# (sandbox/rebuild.sh) does compose down/up + the file copies, then calls this.
# Run it inside the bench container as the `frappe` user:
#
#   docker compose -p erpnext-sandbox exec bench bash -lc "bash /tmp/scripts/rebuild-apps.sh"
#
# What it does, per app (see APPS below):
#   1. stage the local source (under /tmp, never straight into apps/)
#   2. install via the generic installer + that app's recipe
#   3. run any declared post-install fix (only when the source does NOT
#      already carry it — a durable fork needs none)
#   4. verify (list-apps + the recipe's verify doctype over REST)
# Finally: restart serve and ping.
#
# Sources are LOCAL DIRECTORIES (./repos/*), which is why this is a workspace
# convenience, not a shareable installer: it expects the host to have staged
# them into /tmp first (the host wrapper does).
#
# Idempotent: re-running installs/updates over an existing install. It does NOT
# drop the DB — start from a clean base if you want a truly fresh install.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
VERSION="${VERSION:-16}"
SRCROOT="${SRCROOT:-/tmp}"
RECIPEDIR="${RECIPEDIR:-/tmp/recipes}"
SCRIPTDIR="${SCRIPTDIR:-/tmp/scripts}"

# ---- the manifest: app_name | source dir under $SRCROOT | recipe | post-fix ----
# post-fix is a script in $SCRIPTDIR run after install, or "" for none.
# barcode_shrdc installs from the DURABLE FORK, so it needs NO post-fix.
# amazon_integration is locally authored and also needs none.
APPS=(
  "barcode_shrdc|barcode-shrdc-v16|barcode_shrdc.yaml|"
  "amazon_integration|amazon-integration-src|amazon_integration.yaml|"
)

fail=0
for entry in "${APPS[@]}"; do
  IFS='|' read -r app src recipe postfix <<< "$entry"
  echo
  echo "######################## $app ########################"
  src_dir="$SRCROOT/$src"
  if [ ! -d "$src_dir" ]; then
    echo "ERROR: source dir $src_dir missing — did the host stage it?"
    fail=1; continue
  fi

  echo "-- ensure the staged source is frappe-owned (it arrives root-owned from cp)"
  sudo chown -R "$(id -un):$(id -gn)" "$src_dir" 2>/dev/null || true

  echo "-- install from $src_dir"
  if [ -n "$recipe" ] && [ -f "$RECIPEDIR/$recipe" ]; then
    "$SCRIPTDIR/install-app.sh" "$app" "$src_dir" "$VERSION" "$RECIPEDIR/$recipe"
  else
    "$SCRIPTDIR/install-app.sh" "$app" "$src_dir" "$VERSION"
  fi
  rc=$?
  [ "$rc" -ne 0 ] && { echo "ERROR: install-app.sh failed for $app (rc=$rc)"; fail=1; continue; }

  if [ -n "$postfix" ]; then
    echo "-- post-install fix: $postfix"
    if [ -f "$SCRIPTDIR/$postfix" ]; then
      bash "$SCRIPTDIR/$postfix" || { echo "WARN: post-fix $postfix failed"; }
    else
      echo "WARN: post-fix $postfix not found in $SCRIPTDIR"
    fi
  else
    echo "-- no post-install fix declared (source already carries the fixes)"
  fi
done

echo
echo "######################## finalise ########################"
bench --site "$SITE" clear-cache >/dev/null 2>&1 || true
pkill -f 'frappe serve' 2>/dev/null || true
pkill -f 'bench serve' 2>/dev/null || true
sleep 3
( cd /home/frappe/frappe-bench && setsid nohup bench serve --port 8000 > /tmp/bench-serve.log 2>&1 < /dev/null & disown )
for i in $(seq 1 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SITE" http://localhost:8000/api/method/ping || true)" = "200" ] \
    && { echo "  serve up after ${i}s"; break; }
  sleep 1
done

echo
echo "######################## summary ########################"
bench --site "$SITE" list-apps | sed 's/^/  /'
for entry in "${APPS[@]}"; do
  IFS='|' read -r app src recipe postfix <<< "$entry"
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SITE" \
    "http://localhost:8000/api/method/ping")
  echo "  $app: source=$src postfix=${postfix:-none}"
done
echo "  ping=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SITE" http://localhost:8000/api/method/ping)"

echo
if [ "$fail" -ne 0 ]; then
  echo "REBUILD-APPS: COMPLETED WITH ERRORS — review above"
  exit 1
fi
echo "REBUILD-APPS: OK"
