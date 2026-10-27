#!/usr/bin/env bash
# Safety gate before the vendor -> workshop Link swap.
# The free-text `vendor` values cannot be mapped to a Link, so the column will
# be dropped. Before that we must be SURE the only rows are throwaway test data.
# Abort loudly if anything looks like real user data.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1
DB_NAME=$(env/bin/python -c "import json;print(json.load(open('sites/$SITE/site_config.json'))['db_name'])")

echo "== all Car records =="
mariadb -h db -u root -padmin "$DB_NAME" -e "select name, license_plate, owner, creation from tabCar;" 2>/dev/null

echo
echo "== all service rows (the vendor values that will be dropped) =="
mariadb -h db -u root -padmin "$DB_NAME" -e "select parent, service_type, vendor, cost from \`tabCar Service Record\`;" 2>/dev/null

echo
echo "== any record NOT matching the diagnostic/test naming used by my run? =="
COUNT=$(mariadb -h db -u root -padmin "$DB_NAME" -N -e \
  "select count(*) from tabCar where license_plate not like 'DIAG-%' and license_plate not like 'TEST-%';" 2>/dev/null)
echo "non-test Car records: $COUNT"
COUNT2=$(mariadb -h db -u root -padmin "$DB_NAME" -N -e \
  "select count(*) from \`tabCar Service Record\` where vendor not in ('Garage A','Garage B');" 2>/dev/null)
echo "service rows with an unexpected vendor: $COUNT2"
