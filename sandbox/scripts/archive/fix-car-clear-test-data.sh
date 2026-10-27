#!/usr/bin/env bash
# Delete the leftover diagnostic car before the vendor -> workshop schema swap.
# Safe per verify-car-datagate.sh: 0 non-test records, 0 unexpected vendors.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

APP_DIR=apps/car_tracker/car_tracker
mkdir -p "$APP_DIR/_diag"
cat > "$APP_DIR/_diag/__init__.py" <<'PYEOF'
PYEOF
cat > "$APP_DIR/_diag/run.py" <<'PYEOF'
import frappe


def cleanup():
	frappe.set_user("Administrator")
	removed = 0
	for name in frappe.get_all("Car", pluck="name"):
		frappe.delete_doc("Car", name, force=1, ignore_permissions=True)
		removed += 1
	print("removed cars:", removed)
	print("cars remaining:", frappe.db.count("Car"))
PYEOF

bench --site "$SITE" execute car_tracker._diag.run.cleanup
rm -rf "$APP_DIR/_diag"
