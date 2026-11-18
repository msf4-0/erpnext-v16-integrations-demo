#!/usr/bin/env bash
# Verify the get_item_details class-method whitelist fix with a fully-formed
# run_doc_method payload (includes `modified` so check_if_latest passes).
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bpverify
mkdir -p "$J"

cat > /tmp/_latest.py <<'PYEOF'
import frappe, json
d = frappe.get_doc("Barcode Printing", frappe.get_all("Barcode Printing", limit=1, pluck="name")[0])
item = frappe.get_all("Item", limit=1, pluck="name")[0]
open("/tmp/bpverify/payload2.json","w").write(json.dumps({
    "docs": {"doctype": "Barcode Printing", "name": d.name, "modified": str(d.modified)},
    "method": "get_item_details",
    "args": {"item_code": item, "qty": 1, "company": d.company},
}))
open("/tmp/bpverify/who.txt","w").write("doc=%s item=%s company=%s\n" % (d.name, item, d.company))
PYEOF
bench --site "$SITE" console < /tmp/_latest.py > /dev/null 2>&1
cat "$J/who.txt"; echo "payload: $(cat "$J/payload2.json")"

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o "$J/login" -w "login=%{http_code}\n"

echo
echo "== run_doc_method class get_item_details (expect 200) =="
curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/frappe.handler.run_doc_method" \
  --data-binary @"$J/payload2.json" -o "$J/b.out" -w "http=%{http_code}\n"
head -c 900 "$J/b.out"; echo
