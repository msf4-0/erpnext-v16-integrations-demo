#!/usr/bin/env bash
# Robust reset of the amazon_integration install (fixes the earlier helper,
# which hit ImplicitCommitError on a raw DROP and a NameError, leaving a
# leftover Module Def that then made `bench install-app` fail on a duplicate).
#
# Order matters: delete the DocType first (removes its table + DocField/DocPerm
# rows), then the Module Def, then the registries.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend

cat > apps/barcode_shrdc/barcode_shrdc/_amzreset2.py <<'PYEOF'
import frappe


def run():
    if frappe.db.exists("DocType", "Amazon Account"):
        frappe.delete_doc("DocType", "Amazon Account", force=True, ignore_permissions=True)
        print("MARK deleted DocType Amazon Account")
    # table may linger if doctype row was already gone
    if frappe.db.sql("SHOW TABLES LIKE 'tabAmazon Account'"):
        frappe.db.sql_ddl("DROP TABLE IF EXISTS `tabAmazon Account`")
        print("MARK dropped table tabAmazon Account")

    if frappe.db.exists("Module Def", "Amazon Integration"):
        frappe.delete_doc("Module Def", "Amazon Integration", force=True, ignore_permissions=True)
        print("MARK deleted Module Def Amazon Integration")

    # registries: DB global + the Installed Applications Single
    apps = [a for a in frappe.get_installed_apps() if a != "amazon_integration"]
    frappe.db.set_global("installed_apps", frappe.as_json(apps))
    ia = frappe.get_single("Installed Applications")
    ia.installed_applications = [r for r in ia.installed_applications if r.app_name != "amazon_integration"]
    ia.save(ignore_permissions=True)
    frappe.db.commit()
    frappe.clear_cache()
    print("MARK db global:", frappe.db.get_global("installed_apps"))
    print("MARK get_installed_apps:", frappe.get_installed_apps())
PYEOF
bench --site "$SITE" execute barcode_shrdc._amzreset2.run 2>&1 | grep -E '^MARK|Error|Traceback' | sed 's/^/  /'
rm -f apps/barcode_shrdc/barcode_shrdc/_amzreset2.py

echo
echo "== filesystem: app dir, pth, apps.txt, site_config =="
sudo rm -rf apps/amazon_integration
sudo rm -f env/lib/python*/site-packages/amazon_integration.pth
for f in apps.txt sites/apps.txt; do
  [ -f "$f" ] || continue
  grep -vx amazon_integration "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
done
env/bin/python - <<'PYEOF'
import json
p = "sites/frontend/site_config.json"
c = json.load(open(p))
c["installed_apps"] = [a for a in (c.get("installed_apps") or []) if a != "amazon_integration"]
json.dump(c, open(p, "w"), indent=1)
print("  site_config installed_apps:", c["installed_apps"])
PYEOF

echo
echo "== state after reset =="
ls -d apps/amazon_integration 2>/dev/null && echo "  WARN dir" || echo "  no app dir"
bench --site "$SITE" list-apps | sed 's/^/  /'
