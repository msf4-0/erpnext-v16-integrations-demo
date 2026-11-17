#!/usr/bin/env bash
# Reset the barcode_shrdc install so we can prove a fresh install FROM THE FORK
# needs no post-install patching.
#   - uninstall-app barcode_shrdc (drops its tables + fixtures)
#   - clean registries (DB global, Installed Applications, apps.txt, site_config)
#   - remove apps/barcode_shrdc + the .pth
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
APP=barcode_shrdc

echo "== uninstall-app (drops doctypes/fixtures) =="
bench --site "$SITE" uninstall-app "$APP" --yes --no-backup 2>&1 | tail -6 | sed 's/^/  /'

echo
echo "== registry cleanup =="
cat > apps/amazon_integration/amazon_integration/_cleanreg.py <<'PYEOF'
import frappe


def run():
    apps = [a for a in frappe.get_installed_apps() if a != "barcode_shrdc"]
    frappe.db.set_global("installed_apps", frappe.as_json(apps))
    ia = frappe.get_single("Installed Applications")
    ia.installed_applications = [r for r in ia.installed_applications if r.app_name != "barcode_shrdc"]
    ia.save(ignore_permissions=True)
    frappe.db.commit()
    frappe.clear_cache()
    print("MARK get_installed_apps:", frappe.get_installed_apps())
    print("MARK Installed Applications:", [r.app_name for r in frappe.get_single("Installed Applications").installed_applications])
PYEOF
bench --site "$SITE" execute amazon_integration._cleanreg.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f apps/amazon_integration/amazon_integration/_cleanreg.py

echo
echo "== filesystem =="
sudo rm -rf "apps/$APP"
sudo rm -f env/lib/python*/site-packages/$APP.pth
for f in apps.txt sites/apps.txt; do
  [ -f "$f" ] || continue
  grep -vx "$APP" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
done
env/bin/python - <<'PYEOF'
import json
p = "sites/frontend/site_config.json"
c = json.load(open(p))
c["installed_apps"] = [a for a in (c.get("installed_apps") or []) if a != "barcode_shrdc"]
json.dump(c, open(p, "w"), indent=1)
print("  site_config:", c["installed_apps"])
PYEOF

echo
echo "== state after reset =="
ls -d "apps/$APP" 2>/dev/null && echo "  WARN dir" || echo "  no app dir"
bench --site "$SITE" list-apps | sed 's/^/  /'
