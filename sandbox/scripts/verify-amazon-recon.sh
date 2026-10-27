#!/usr/bin/env bash
# Recon for the amazon-integration app: name collisions, roles, master data.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
APP=apps/barcode_shrdc/barcode_shrdc

cat > "$APP/_recon.py" <<'PYEOF'
import frappe


def run():
    for label, filters in (
        ("Amazon*", {"name": ["like", "%Amazon%"]}),
        ("Marketplace*", {"name": ["like", "%Marketplace%"]}),
        ("Seller*", {"name": ["like", "%Seller%"]}),
        ("Ecommerce*", {"name": ["like", "%Ecommerce%"]}),
        ("Account*", {"name": ["like", "Account%"]}),
    ):
        print("MARK doctype %-14s %s" % (label, frappe.get_all("DocType", filters=filters, pluck="name")))
    print("MARK module Amazon*:", frappe.get_all("Module Def", filters={"name": ["like", "%Amazon%"]}, pluck="name"))
    roles = ["System Manager", "Accounts Manager", "Purchase Manager", "Sales Manager",
             "Stock Manager", "Item Manager", "All", "Accounts User", "Sales User",
             "Purchase User", "Ecommerce Manager", "Website Manager"]
    print("MARK roles present:", frappe.get_all("Role", filters={"name": ["in", roles]}, pluck="name"))
    print("MARK companies:", frappe.get_all("Company", pluck="name"))
    print("MARK currencies enabled:", frappe.get_all("Currency", filters={"enabled": 1}, limit=8, pluck="name"))
    print("MARK default currency:", frappe.db.get_default("currency"))
PYEOF
bench --site "$SITE" execute barcode_shrdc._recon.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f "$APP/_recon.py"
