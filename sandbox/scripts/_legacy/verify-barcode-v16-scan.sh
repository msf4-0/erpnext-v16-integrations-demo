#!/usr/bin/env bash
# Check v16 whitelisted alternatives for the JS calls the app makes.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
E=/home/frappe/frappe-bench/apps/erpnext/erpnext

echo "== scan_barcode decorator + return shape =="
grep -n "def scan_barcode" -B6 "$E/stock/utils.py" | sed 's/^/  /'
grep -n "def scan_barcode" -A 80 "$E/stock/utils.py" | grep -n "return\|item_code\|_update_item_info" | head -20 | sed 's/^/  /'

echo
echo "== is scan_barcode whitelisted? =="
cat > /tmp/_sb.py <<'PYEOF'
import frappe
from frappe import whitelisted
from erpnext.stock.utils import scan_barcode
print("MARK scan_barcode whitelisted:", scan_barcode in whitelisted)
PYEOF
bench --site frontend console < /tmp/_sb.py 2>&1 | grep '^MARK' | sed 's/^/  /'

echo
echo "== assets path for serial_no_batch_selector.js =="
ls -la "$E/public/js/utils/serial_no_batch_selector.js" 2>/dev/null | sed 's/^/  /'
ls -la "/home/frappe/frappe-bench/sites/assets/erpnext/js/utils/serial_no_batch_selector.js" 2>/dev/null | sed 's/^/  /'
curl -s -o /dev/null -w "  HTTP /assets/erpnext/js/utils/serial_no_batch_selector.js = %{http_code}\n" \
  -H "Host: frontend" "http://localhost:8000/assets/erpnext/js/utils/serial_no_batch_selector.js"

echo
echo "== does the erpnext bundle define SerialBatchPackageSelector + scan_barcode? =="
grep -o "erpnext.SerialBatchPackageSelector" "$E/public/dist/js/erpnext.bundle"*.js 2>/dev/null | head -1 | sed 's/^/  /'
grep -o "erpnext.scan_barcode" "$E/public/dist/js/erpnext.bundle"*.js 2>/dev/null | head -1 | sed 's/^/  /'

echo
echo "== stock_entry.js barcode scanner reference =="
grep -n "scan_barcode\|get_item_code" "$E/stock/doctype/stock_entry/stock_entry.js" | head | sed 's/^/  /'
