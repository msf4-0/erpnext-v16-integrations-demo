#!/usr/bin/env bash
# Verify the Device doctype ACTUALLY materialized in the v16 DB schema —
# table exists, columns present, permissions set — rather than trusting that
# the file was copied.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

echo "== reload_doc signature on THIS version (my earlier call used a bad kwarg) =="
bench --site "$SITE" execute frappe.reload_doc 2>&1 | tail -3
python3 - <<'PY'
import inspect, sys
sys.path.insert(0, "/home/frappe/frappe-bench/apps/frappe")
from frappe.model.sync import sync_for
from frappe.modules import reload_doc
print("reload_doc signature:", inspect.signature(reload_doc))
print("sync_for signature:", inspect.signature(sync_for))
PY

echo
echo "== DocType record in DB =="
bench --site "$SITE" execute frappe.client.get_list --kwargs \
  "{'doctype':'DocType','filters':{'name':'Device'},'fields':['name','module','autoname','naming_rule','is_submittable','istable','issingle','track_changes'],'limit_page_length':5}"

echo
echo "== does the table + its columns exist in the DB? (SQL, not just metadata) =="
DB_NAME=$(python3 -c "import json;print(json.load(open('sites/$SITE/site_config.json'))['db_name'])")
echo "db_name=$DB_NAME"
mysql -h db -u root -padmin "$DB_NAME" -e "SHOW TABLES LIKE 'tabDevice';" 2>/dev/null
echo "-- columns --"
mysql -h db -u root -padmin "$DB_NAME" -e "SHOW COLUMNS FROM \`tabDevice\`;" 2>/dev/null

echo
echo "== permissions rows for Device =="
mysql -h db -u root -padmin "$DB_NAME" -e "SELECT role, permlevel, read_perm AS r, write_perm AS w, create_perm AS c, delete_perm AS d FROM \`tabDocPerm\` WHERE parent='Device';" 2>/dev/null
