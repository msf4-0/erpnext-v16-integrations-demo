#!/usr/bin/env bash
# Drop the ORPHAN physical `vendor` column on tabCar Service Record.
#
# Frappe's migrate is non-destructive: it added the new `workshop` /
# `workshop_phone` columns but did NOT drop `vendor` when the field was removed
# from the DocType. The column is no longer referenced by any DocField (so it is
# invisible in the UI and never written), but it lingers in the table.
#
# Safe here because: the data gate (verify-car-datagate.sh) proved the only
# values were my own test data (Garage A/Garage B), and the table is now empty.
# Idempotent: drops only if the column exists and the table is empty; refuses
# otherwise.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1
DB_NAME=$(env/bin/python -c "import json;print(json.load(open('sites/$SITE/site_config.json'))['db_name'])")

ROWS=$(mariadb -h db -u root -padmin "$DB_NAME" -N -e "select count(*) from \`tabCar Service Record\`;" 2>/dev/null)
COLS=$(mariadb -h db -u root -padmin "$DB_NAME" -N -e \
  "select count(*) from information_schema.columns where table_schema='$DB_NAME' and table_name='tabCar Service Record' and column_name='vendor';" 2>/dev/null)

echo "rows in tabCar Service Record: $ROWS"
echo "vendor columns present: $COLS"

if [ "$COLS" -eq 0 ]; then
  echo "no orphan column — nothing to do"
  exit 0
fi

if [ "$ROWS" -ne 0 ]; then
  echo "REFUSING to drop: table is not empty ($ROWS rows). Investigate first."
  exit 1
fi

mariadb -h db -u root -padmin "$DB_NAME" -e \
  "alter table \`tabCar Service Record\` drop column \`vendor\`;" 2>/dev/null
echo "dropped orphan vendor column"

echo "== verify =="
mariadb -h db -u root -padmin "$DB_NAME" -e \
  "select column_name from information_schema.columns where table_schema='$DB_NAME' and table_name='tabCar Service Record' order by ordinal_position;" 2>/dev/null
