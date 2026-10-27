#!/usr/bin/env bash
# Verify the amazon_integration install: app registered, doctype present, schema.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend

echo "== list-apps =="
bench --site "$SITE" list-apps | sed 's/^/  /'

echo
echo "== module dir + .pth =="
ls apps/amazon_integration/amazon_integration/ | sed 's/^/  /'
cat env/lib/python*/site-packages/amazon_integration.pth 2>/dev/null | sed 's/^/  pth -> /'

echo
echo "== install-log tail (errors?) =="
ls -t sites/$SITE/logs/*.log 2>/dev/null | head -3 | sed 's/^/  /'

echo
echo "== DB: doctype + module + columns + permissions =="
cat > apps/amazon_integration/amazon_integration/_chk.py <<'PYEOF'
import frappe


def run():
    print("MARK doctype exists:", bool(frappe.db.exists("DocType", "Amazon Account")))
    print("MARK module exists:", bool(frappe.db.exists("Module Def", "Amazon Integration")))
    print("MARK module in doctype:", frappe.db.get_value("DocType", "Amazon Account", "module"))
    cols = frappe.db.sql("SHOW COLUMNS FROM `tabAmazon Account`", as_dict=1)
    print("MARK columns:", [(c.Field, c.Type, c.Null, c.Key) for c in cols])
    fields = frappe.get_all(
        "DocField",
        filters={"parent": "Amazon Account"},
        fields=["fieldname", "fieldtype", "label", "reqd", "unique", "options"],
        order_by="idx",
    )
    for f in fields:
        print("MARK field:", f.fieldname, "|", f.fieldtype, "| reqd", f.reqd, "| unique", f.unique, "|", (f.options or "").replace("\n", "/"))
    perms = frappe.get_all(
        "DocPerm",
        filters={"parent": "Amazon Account"},
        fields=["role", "read", "write", "create", "delete"],
    )
    for p in perms:
        print("MARK perm:", p)
PYEOF
bench --site "$SITE" execute amazon_integration._chk.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f apps/amazon_integration/amazon_integration/_chk.py

echo
echo "== ping =="
curl -s -o /dev/null -w "  ping=%{http_code}\n" -H "Host: $SITE" http://localhost:8000/api/method/ping
