#!/usr/bin/env bash
# ai-fix-postsetup.sh — everything that must happen AFTER the apps are installed
# and BEFORE you can trust the Shopify bridge or edit an Item.
#
# Order matters:
#   1. fix_shopify_show_in_website  - the shopify app reads Item.show_in_website,
#      which ERPNext v16 does not have. Once a Shopify Access record exists the
#      guard stops short-circuiting and EVERY Item save dies with AttributeError.
#      This must land before anything touches an Item.
#   2. bootstrap_masters            - Company, chart of accounts, UOM, Item Group,
#      Customer Group, Territory, Price List, Fiscal Year and Global Defaults.
#      A `new-site --install-app erpnext` site has none of these, so every sync
#      and every Item insert fails with MandatoryError / LinkValidationError /
#      "Please specify Company" / FiscalYearError.
#   3. shopify_sync                 - create Shopify Access, then import products
#      as Items and orders as Sales Orders. This is the proof the link is live.
#
# Run inside the bench container:
#   bash /tmp/scripts/ai-fix-postsetup.sh <shpat_token> [store] [api_version] \
#        [client_id] [client_secret]
#
# The last two are the Dev Dashboard app credentials. They are persisted into
# site_config.json so shopify.auth can mint a fresh 24 h Admin API token on
# demand instead of relying on the static (daily-expiring) shpat_ token.
set -uo pipefail

TOKEN="${1:-}"
STORE="${2:-4e1075.myshopify.com}"
VERSION="${3:-2026-04}"
CLIENT_ID="${4:-}"
CLIENT_SECRET="${5:-}"
SCRIPTS=/tmp/scripts

if [ -z "$TOKEN" ]; then
  echo "usage: $0 <shpat_token> [store] [api_version] [client_id] [client_secret]"
  exit 2
fi

cd /home/frappe/frappe-bench || exit 1

run() {
  echo
  echo "=============== $* ==============="
}

run "1/3 shopify Item.show_in_website fix"
if [ -f "$SCRIPTS/fix_shopify_show_in_website.py" ]; then
  env/bin/python "$SCRIPTS/fix_shopify_show_in_website.py" || echo "WARN: patch reported problems"
else
  echo "WARN: $SCRIPTS/fix_shopify_show_in_website.py missing"
fi

run "2/3 ERPNext master data bootstrap"
if [ -f "$SCRIPTS/bootstrap_masters.py" ]; then
  env/bin/python "$SCRIPTS/bootstrap_masters.py" || { echo "ERROR: bootstrap failed"; exit 1; }
else
  echo "ERROR: $SCRIPTS/bootstrap_masters.py missing"; exit 1
fi

run "3/3 Shopify Access + product/order sync"
if [ -f "$SCRIPTS/shopify_sync.py" ]; then
  env/bin/python "$SCRIPTS/shopify_sync.py" "$TOKEN" "$STORE" "$VERSION" "$CLIENT_ID" "$CLIENT_SECRET"
else
  echo "ERROR: $SCRIPTS/shopify_sync.py missing"; exit 1
fi

run "4/4 enable Server Scripts (planner schedule-write endpoint)"
# The planner moves a Job Card through the whitelisted Server Script
# `planner_shift_job_card` (seed-vwo-doctype.py) because ERPNext's
# JobCard.validate_sequence_id refuses a normal save for any operation after
# the first one until the previous operation has completed qty. Server Scripts
# are off by default, and without this flag that endpoint answers 403.
bench set-config -g server_script_enabled 1 >/dev/null 2>&1 \
  && echo "-- server_script_enabled = 1" \
  || echo "WARN: could not enable server scripts (planner JC drag will fall back to PUT)"

run "restart serve so patched python is loaded"
pkill -f 'frappe serve' 2>/dev/null
sleep 3
( cd /home/frappe/frappe-bench && setsid nohup bench serve --port 8000 > /tmp/bench-serve.log 2>&1 < /dev/null & disown )
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${SITE_NAME:-frontend}" http://localhost:8000/api/method/ping || true)
  [ "$code" = "200" ] && { echo "serve up (ping 200)"; break; }
  sleep 2
done

echo
echo "POSTSETUP DONE"
