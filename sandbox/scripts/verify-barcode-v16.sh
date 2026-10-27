#!/usr/bin/env bash
# Verify the barcode_shrdc (ERPNext Barcode Integration) app on ERPNext v16.
# Runs INSIDE the bench container (container-internal port 8000), like
# verify-v16-base.sh. Confirms the doctypes exist, the client-script fixtures
# synced, the module imports, and authenticated REST returns 200.
set -uo pipefail
SITE=frontend
cd /home/frappe/frappe-bench || exit 1

echo "-- bench version --"
bench version

echo "-- list-apps --"
bench --site "$SITE" list-apps

echo "-- doctypes (module Barcode Shrdc) --"
bench --site "$SITE" execute frappe.client.get_list --kwargs \
  "{\"doctype\":\"DocType\",\"filters\":{\"module\":\"Barcode Shrdc\"},\"fields\":[\"name\"],\"limit_page_length\":0}"

echo "-- Client Script fixtures --"
bench --site "$SITE" execute frappe.client.get_list --kwargs \
  "{\"doctype\":\"Client Script\",\"fields\":[\"dt\",\"name\"],\"limit_page_length\":0}"

echo "-- module import (real import of hooks + controller) --"
cat > /tmp/_vb_import.py <<'PYEOF'
import barcode_shrdc.hooks as h
print("import barcode_shrdc.hooks: OK, app_name =", getattr(h, "app_name", "?"))
from barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing import BarcodePrinting
print("import controller BarcodePrinting: OK")
PYEOF
bench --site "$SITE" console < /tmp/_vb_import.py 2>&1 | grep -E 'import .*(OK|Error)|Traceback' || echo "import check produced no OK line"

echo "-- custom fields from the app fixture (expect 20, incl. the 5 formerly shadowed) --"
cat > /tmp/_vb_fields.py <<'PYEOF'
import json
import frappe
p = "/home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc/fixtures/custom_field.json"
d = json.load(open(p))
missing = [f"{x.get('dt')}-{x.get('fieldname')}" for x in d
           if not frappe.db.exists("Custom Field", f"{x.get('dt')}-{x.get('fieldname')}")]
print("fixture records:", len(d), "| missing in DB:", missing)
PYEOF
bench --site "$SITE" console < /tmp/_vb_fields.py 2>&1 | grep -E 'fixture records'

echo "-- the 5 barcode fields the Frepple record used to shadow --"
bench --site "$SITE" execute frappe.client.get_list --kwargs \
  "{\"doctype\":\"Custom Field\",\"filters\":{\"fieldname\":[\"in\",[\"barcode_validation\",\"stock_check\",\"checking_qty\",\"reference_dt\",\"reference_dn\"]]},\"fields\":[\"dt\",\"fieldname\"],\"limit_page_length\":0}"

echo "-- site ping (internal :8000) --"
curl -s -o /dev/null -w "ping: %{http_code}\n" -H "Host: $SITE" \
  http://localhost:8000/api/method/ping

echo "-- REST: login + GET /api/resource/Barcode Printing --"
curl -s -c /tmp/vbc.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' \
  http://localhost:8000/api/method/login >/dev/null
CODE=$(curl -s -b /tmp/vbc.txt -H "Host: $SITE" -o /dev/null -w "%{http_code}" \
  "http://localhost:8000/api/resource/Barcode%20Printing?limit_page_length=1")
echo "REST Barcode Printing: $CODE"
