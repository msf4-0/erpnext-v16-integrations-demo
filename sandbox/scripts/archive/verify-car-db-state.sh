#!/usr/bin/env bash
# Report residual Car test data straight from the DB (no backtick quoting
# through PowerShell: this runs as a file inside the container).
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1
DB_NAME=$(env/bin/python -c "import json;print(json.load(open('sites/$SITE/site_config.json'))['db_name'])")

echo "== cars remaining =="
mariadb -h db -u root -padmin "$DB_NAME" -e "select name, license_plate, service_status from tabCar;" 2>/dev/null

echo
echo "== child rows remaining =="
mariadb -h db -u root -padmin "$DB_NAME" -e "select count(*) as child_rows from \`tabCar Service Record\`;" 2>/dev/null

echo
echo "== series counter for CAR- =="
mariadb -h db -u root -padmin "$DB_NAME" -e "select name, current from \`tabSeries\` where name like 'CAR-%';" 2>/dev/null
