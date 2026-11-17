#!/usr/bin/env bash
# Gather remaining v16 facts needed to fix the barcode app.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
E=/home/frappe/frappe-bench/apps/erpnext/erpnext
A=/home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc

echo "== v16 Serial No fields (removed ones?) =="
for f in purchase_date purchase_document_no delivery_date delivery_document_no \
         warranty_expiry_date amc_expiry_date; do
  n=$(grep -c "\"$f\"" "$E/stock/doctype/serial_no/serial_no.json" 2>/dev/null || true)
  echo "  Serial No '$f' -> $n"
done

echo
echo "== child doctype Barcode Generator Items fields =="
env/bin/python - <<'PYEOF'
import json
d = json.load(open("/home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc/barcode_shrdc/doctype/barcode_generator_items/barcode_generator_items.json"))
print("  fields:", [f["fieldname"] for f in d["fields"]])
PYEOF

echo
echo "== app requirements / installed render deps =="
cat "$A/../requirements.txt" 2>/dev/null | sed 's/^/  /'
env/bin/pip list 2>/dev/null | grep -iE 'reportlab|rlpycairo|qrcode|pillow' | sed 's/^/  /'

echo
echo "== item_qr page over HTTP (needs an item) =="
cat > /tmp/_iq.py <<'PYEOF'
import frappe
i = frappe.get_all("Item", limit=1, pluck="name")
open("/tmp/iq_item.txt","w").write(i[0] if i else "")
PYEOF
bench --site frontend console < /tmp/_iq.py >/dev/null 2>&1
ITEM=$(cat /tmp/iq_item.txt)
echo "  item=[$ITEM]"
curl -s -o /tmp/iq.html -w "  /item_qr?item_code=$ITEM http=%{http_code}\n" \
  -H "Host: frontend" "http://localhost:8000/item_qr?item_code=$ITEM"
grep -o '<title>[^<]*</title>' /tmp/iq.html | head -1 | sed 's/^/  /'
grep -c 'Item Details (QR Code Scanning)' /tmp/iq.html | sed 's/^/  title-string count: /'

echo
echo "== is get_item_code whitelisted? (barcode -> item_code JS path) =="
cat > /tmp/_gic.py <<'PYEOF'
import frappe
from frappe import whitelisted
from erpnext.stock.get_item_details import get_item_code
open("/tmp/gic.txt","w").write("get_item_code whitelisted: %s\n" % (get_item_code in whitelisted))
PYEOF
bench --site frontend console < /tmp/_gic.py >/dev/null 2>&1
cat /tmp/gic.txt | sed 's/^/  /'

echo
echo "== ping =="
curl -s -o /dev/null -w "  ping=%{http_code}\n" -H "Host: frontend" http://localhost:8000/api/method/ping
