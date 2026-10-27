#!/usr/bin/env bash
# Verify the barcode_shrdc v16 get_item_details class-method whitelist fix.
# Uses a REAL saved Barcode Printing doc (run_doc_method needs a saved doc).
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bpverify
rm -rf "$J"; mkdir -p "$J"

# 1. seed a real doc + discover company/item; Python writes the JSON file itself
cat > /tmp/_seed.py <<'PYEOF'
import frappe, json
company = frappe.get_all("Company", limit=1, pluck="name")
item = frappe.get_all("Item", limit=1, pluck="name")
company = company[0] if company else None
item = item[0] if item else None
data = {"company": company, "item": item, "doc": None}
if company and item:
    existing = frappe.get_all("Barcode Printing", limit=1, pluck="name")
    if existing:
        data["doc"] = existing[0]
    else:
        d = frappe.new_doc("Barcode Printing")
        d.company = company
        d.append("items", {"item_code": item, "qty": 1})
        d.insert(ignore_permissions=True)
        frappe.db.commit()
        data["doc"] = d.name
open("/tmp/bpverify/info.json", "w").write(json.dumps(data))
PYEOF
bench --site "$SITE" console < /tmp/_seed.py > /dev/null 2>&1
echo "info.json: $(cat "$J/info.json" 2>/dev/null || echo MISSING)"
COMPANY=$(python3 -c "import json;print(json.load(open('$J/info.json'))['company'])")
ITEM=$(python3 -c "import json;print(json.load(open('$J/info.json'))['item'])")
DOC=$(python3 -c "import json;print(json.load(open('$J/info.json'))['doc'])")
echo "company=$COMPANY item=$ITEM doc=$DOC"

# 2. login
curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o "$J/login" -w "login=%{http_code}\n"

# 3. craft the run_doc_method payload as a file (real saved doc)
cat > "$J/payload.json" <<JSONEOF
{"docs":{"doctype":"Barcode Printing","name":"$DOC"},"method":"get_item_details","args":{"item_code":"$ITEM","qty":1,"company":"$COMPANY"}}
JSONEOF

echo
echo "== A) run_doc_method class get_item_details (expect 200, was 403) =="
curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/frappe.handler.run_doc_method" \
  --data-binary @"$J/payload.json" -o "$J/a.out" -w "http=%{http_code}\n"
head -c 900 "$J/a.out"; echo

echo
echo "== B) is the class method whitelisted now? (write to file) =="
cat > /tmp/_wl2.py <<'PYEOF'
import frappe
from frappe import whitelisted
from barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing import BarcodePrinting
open("/tmp/bpverify/wl.txt","w").write("class method in whitelisted set: %s\n" % (BarcodePrinting.get_item_details in whitelisted))
PYEOF
bench --site "$SITE" console < /tmp/_wl2.py > /dev/null 2>&1
cat "$J/wl.txt" 2>/dev/null || echo "wl.txt MISSING"

echo
echo "== C) site ping =="
curl -s -o /dev/null -w "ping=%{http_code}\n" -H "Host: $SITE" "$B/api/method/ping"
