#!/usr/bin/env bash
# list-apps reads the `Installed Applications` Single doctype's child rows (not
# site_config / the DB global). Remove the amazon_integration row there.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend

cat > apps/barcode_shrdc/barcode_shrdc/_amzia.py <<'PYEOF'
import frappe


def run():
    doc = frappe.get_single("Installed Applications")
    before = [r.app_name for r in doc.installed_applications]
    print("MARK before:", before)
    doc.installed_applications = [r for r in doc.installed_applications if r.app_name != "amazon_integration"]
    doc.save(ignore_permissions=True)
    frappe.db.commit()
    frappe.clear_cache()
    print("MARK after:", [r.app_name for r in frappe.get_single("Installed Applications").installed_applications])
PYEOF
bench --site "$SITE" execute barcode_shrdc._amzia.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f apps/barcode_shrdc/barcode_shrdc/_amzia.py

echo
echo "== list-apps now =="
bench --site "$SITE" list-apps | sed 's/^/  /'
