#!/usr/bin/env bash
# Permissions for Car Workshop, plus a check that the orphan `vendor` column is
# still present in the TABLE while no longer being a DocField (frappe.migrate
# does not drop removed columns).
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1
DB_NAME=$(env/bin/python -c "import json;print(json.load(open('sites/$SITE/site_config.json'))['db_name'])")

echo "== Car Workshop permissions =="
mariadb -h db -u root -padmin "$DB_NAME" -e \
  "select role, permlevel, \`read\` AS r, \`write\` AS w, \`create\` AS c, \`delete\` AS d from \`tabDocPerm\` where parent='Car Workshop' order by idx;" 2>/dev/null

echo
echo "== is 'vendor' still a DocField on Car Service Record? =="
mariadb -h db -u root -padmin "$DB_NAME" -e \
  "select count(*) as vendor_docfields from \`tabDocField\` where parent='Car Service Record' and fieldname='vendor';" 2>/dev/null

echo "== but does the physical column still linger? =="
mariadb -h db -u root -padmin "$DB_NAME" -e \
  "select count(*) as vendor_columns from information_schema.columns where table_schema='$DB_NAME' and table_name='tabCar Service Record' and column_name='vendor';" 2>/dev/null

echo
echo "== Car summary metadata: last_workshop / workshops_used =="
mariadb -h db -u root -padmin "$DB_NAME" -e \
  "select fieldname, fieldtype, options, read_only from \`tabDocField\` where parent='Car' and fieldname in ('last_workshop','workshops_used');" 2>/dev/null
