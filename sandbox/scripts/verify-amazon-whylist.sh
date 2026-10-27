#!/usr/bin/env bash
# Find why list-apps still shows amazon_integration after reset.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend

echo "== sites/apps.txt =="
cat -A sites/apps.txt | sed 's/^/  /'
echo "== root apps.txt =="
cat -A apps.txt 2>/dev/null | sed 's/^/  /' || echo "  (none)"
echo "== site_config installed_apps =="
env/bin/python - <<'PYEOF'
import json
c = json.load(open("sites/frontend/site_config.json"))
print("  ", c.get("installed_apps"))
PYEOF
echo "== clear cache then list-apps =="
bench --site "$SITE" clear-cache >/dev/null 2>&1
bench --site "$SITE" list-apps | sed 's/^/  /'
echo "== installed_apps via DB (tabDefaultValue? / hooks) =="
cat > apps/barcode_shrdc/barcode_shrdc/_whylist.py <<'PYEOF'
import frappe


def run():
    print("MARK installed_apps (frappe.get_installed_apps):", frappe.get_installed_apps())
    print("MARK conf installed_apps:", frappe.conf.get("installed_apps"))
PYEOF
bench --site "$SITE" execute barcode_shrdc._whylist.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f apps/barcode_shrdc/barcode_shrdc/_whylist.py
