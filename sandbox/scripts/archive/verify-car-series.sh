#!/usr/bin/env bash
# Inspect the naming-series counters so sample data can be renumbered cleanly
# (WS-0001.. and CAR-0001..) instead of continuing from earlier test runs.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1
DB_NAME=$(env/bin/python -c "import json;print(json.load(open('sites/$SITE/site_config.json'))['db_name'])")

echo "== series rows =="
mariadb -h db -u root -padmin "$DB_NAME" -e \
  "select name, \`current\` from \`tabSeries\` where name like 'CAR-%' or name like 'WS-%';" 2>/dev/null

echo
echo "== existing sample records (all of them are sample data) =="
mariadb -h db -u root -padmin "$DB_NAME" -e "select name, license_plate from tabCar order by name;" 2>/dev/null
mariadb -h db -u root -padmin "$DB_NAME" -e "select name, workshop_name from \`tabCar Workshop\` order by name;" 2>/dev/null
