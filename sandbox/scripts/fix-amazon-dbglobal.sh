#!/usr/bin/env bash
# The authoritative installed-apps list is a DB global ("installed_apps"), not
# site_config's installed_apps. Clear the entry so list-apps reflects reality.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend

cat > apps/barcode_shrdc/barcode_shrdc/_amzdb.py <<'PYEOF'
import frappe


def run():
    print("MARK before:", frappe.db.get_global("installed_apps"))
    apps = frappe.get_installed_apps()
    apps = [a for a in apps if a != "amazon_integration"]
    frappe.db.set_global("installed_apps", frappe.as_json(apps))
    frappe.db.commit()
    frappe.clear_cache()
    print("MARK after:", frappe.db.get_global("installed_apps"))
    print("MARK get_installed_apps:", frappe.get_installed_apps())
PYEOF
bench --site "$SITE" execute barcode_shrdc._amzdb.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f apps/barcode_shrdc/barcode_shrdc/_amzdb.py

echo
echo "== list-apps now =="
bench --site "$SITE" list-apps | sed 's/^/  /'
