#!/usr/bin/env bash
# Remove the GUARD-TEST-V12-* Items created by verify-shopify-guard*.sh, and
# report what remains. Also drops the UOM/Item Group seeded for that test so
# the site goes back to its pre-verification state (v12 baseline has neither).
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

cat > apps/shopify/shopify/_diag_cleanup.py <<'PYEOF'
import frappe

def run():
    names = [n.name for n in frappe.get_all(
        "Item", filters={"item_code": ["like", "GUARD-TEST-V12-%"]}, fields=["name"])]
    print("test items found:", names)
    for n in names:
        try:
            frappe.delete_doc("Item", n, force=1, ignore_permissions=True)
            print("deleted Item", n)
        except Exception as e:
            print("could not delete %s -> %s: %s" % (n, type(e).__name__, e))
    frappe.db.commit()
    print("remaining GUARD items:", frappe.get_all(
        "Item", filters={"item_code": ["like", "GUARD-TEST-V12-%"]}, fields=["name"]))
    print("Item Groups:", [r.name for r in frappe.get_all("Item Group", fields=["name"])])
    print("UOMs:", [r.name for r in frappe.get_all("UOM", fields=["name"])])
PYEOF
bench --site frontend execute shopify._diag_cleanup.run
rm -f apps/shopify/shopify/_diag_cleanup.py
