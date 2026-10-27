#!/usr/bin/env bash
# Probe the v16 whitelisted barcode->item endpoints the JS can use instead of
# the no-longer-whitelisted erpnext.stock.get_item_details.get_item_code.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bpscan
rm -rf "$J"; mkdir -p "$J"

# find an item that has an Item Barcode row, else just any item
cat > /tmp/_scan_seed.py <<'PYEOF'
import frappe, json
ib = frappe.db.get_value("Item Barcode", {}, ["parent", "barcode"], as_dict=True)
item = frappe.get_all("Item", limit=1, pluck="name")[0]
open("/tmp/bpscan/info.json","w").write(json.dumps(
    {"barcode": (ib.barcode if ib else "NOPE-123"), "item": item}))
PYEOF
bench --site "$SITE" console < /tmp/_scan_seed.py >/dev/null 2>&1
cat "$J/info.json"; echo
BARCODE=$(python3 -c "import json;print(json.load(open('$J/info.json'))['barcode'])")

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o "$J/login" -w "login=%{http_code}\n"

echo
echo "== A) get_item_code (old JS path, expected NOT whitelisted -> 403) =="
curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/erpnext.stock.get_item_details.get_item_code" \
  --data "{\"barcode\":\"$BARCODE\"}" -o "$J/a.out" -w "  http=%{http_code}\n"
head -c 300 "$J/a.out"; echo

echo
echo "== B) scan_barcode (v16 whitelisted replacement) =="
curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/erpnext.stock.utils.scan_barcode" \
  --data "{\"search_value\":\"$BARCODE\"}" -o "$J/b.out" -w "  http=%{http_code}\n"
head -c 500 "$J/b.out"; echo
