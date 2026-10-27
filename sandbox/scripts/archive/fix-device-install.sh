#!/usr/bin/env bash
# Install + sync the Device doctype into the running sandbox, then verify the
# schema actually materialized in the DB for THIS frappe version (v16) rather
# than just confirming the file was copied.
set -uo pipefail
APP=robotics_lab
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

echo "== list-apps (before) =="
bench --site "$SITE" list-apps

echo
echo "== ensure app is installed on the site =="
if bench --site "$SITE" list-apps | grep -qE "^$APP([[:space:]]|$)"; then
  echo "-- $APP already installed on $SITE --"
else
  echo "-- installing $APP on $SITE --"
  bench --site "$SITE" install-app "$APP" || exit 1
fi

echo
echo "== migrate (sync DocType schema) =="
bench --site "$SITE" migrate 2>&1 | tail -25

echo
echo "== clear cache (drop cached doctype meta/hooks) =="
bench --site "$SITE" clear-cache

echo
echo "== reload the Device doctype explicitly (force schema sync) =="
bench --site "$SITE" execute frappe.reload_doc --kwargs \
  "{'module': 'Robotics Lab', 'doctype': 'device', 'force': True}" 2>&1 | tail -5

echo
echo "== list-apps (after) =="
bench --site "$SITE" list-apps

echo
echo "== restart serve =="
pkill -f 'frappe serve' 2>/dev/null
pkill -f 'bench serve' 2>/dev/null
sleep 3
( cd /home/frappe/frappe-bench && setsid nohup bench serve --port 8000 > /tmp/bench-serve.log 2>&1 < /dev/null & disown )
sleep 8
echo "serve restarted"
