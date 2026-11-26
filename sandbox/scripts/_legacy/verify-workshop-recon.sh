#!/usr/bin/env bash
# Recon for the "Car Workshop" design: what data currently exists, and what the
# core Supplier doctype offers as an alternative to a bespoke workshop master.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1
DB_NAME=$(env/bin/python -c "import json;print(json.load(open('sites/$SITE/site_config.json'))['db_name'])")

echo "== existing Car records =="
mariadb -h db -u root -padmin "$DB_NAME" -e "select name, license_plate, owner from tabCar;" 2>/dev/null

echo
echo "== existing child service rows =="
mariadb -h db -u root -padmin "$DB_NAME" -e "select parent, service_type, vendor, cost from \`tabCar Service Record\`;" 2>/dev/null

echo
echo "== core Supplier doctype: field names =="
grep -o '"fieldname": "[a-z_]*"' apps/erpnext/erpnext/buying/doctype/supplier/supplier.json | head -40

echo
echo "== is Supplier a Link target used by core child tables? =="
grep -rl '"options": "Supplier"' apps/erpnext/erpnext/*/doctype/*/*.json 2>/dev/null | head -5

echo
echo "== does any core doctype already use a 'Workshop' concept? =="
grep -rli 'workshop' apps/erpnext/erpnext apps/frappe/frappe --include=*.json 2>/dev/null | head -5
echo "(end)"
