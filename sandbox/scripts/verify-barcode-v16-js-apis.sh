#!/usr/bin/env bash
# Find v16 replacements/whitelisted alternatives for the JS APIs the barcode app
# uses that no longer exist on v16.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
E=/home/frappe/frappe-bench/apps/erpnext/erpnext
echo "== python: barcode->item lookup helpers that ARE whitelisted =="
cat > /tmp/_scan.py <<'PYEOF'
import frappe, importlib, inspect
from frappe import whitelisted
cands = [
    "erpnext.stock.utils.scan_barcode",
    "erpnext.stock.get_item_details.get_item_code",
    "erpnext.stock.get_item_details.get_serial_no",
]
for path in cands:
    mod, fn = path.rsplit(".", 1)
    try:
        f = getattr(importlib.import_module(mod), fn)
        print("MARK %-55s exists whitelisted=%s" % (path, f in whitelisted))
    except Exception as e:
        print("MARK %-55s LOAD ERROR %s" % (path, type(e).__name__))
# any *barcode* whitelisted fns under erpnext.stock
import erpnext.stock as st
print("MARK stock module attrs with barcode:", [a for a in dir(st) if "barcode" in a.lower()])
PYEOF
bench --site frontend console < /tmp/_scan.py 2>&1 | grep '^MARK' | sed 's/^/  /'

echo
echo "== scan_barcode source (if any) =="
F=$(grep -rln "def scan_barcode" "$E" 2>/dev/null | grep -v node_modules | head -1)
echo "  file: $F"
if [ -n "$F" ]; then grep -n "def scan_barcode" -A 25 "$F" | sed 's/^/  /'; fi

echo
echo "== stock_entry.js: barcode field handler (v16 reference) =="
grep -n "barcode" -A 20 "$E/stock/doctype/stock_entry/stock_entry.js" | grep -n "get_item_code\|scan_barcode\|frappe.call" | head -10

echo
echo "== serial_no_batch_selector.js: class + constructor signature =="
S="$E/public/js/utils/serial_no_batch_selector.js"
grep -n "class SerialBatchPackageSelector" -A 30 "$S" | head -45 | sed 's/^/  /'

echo
echo "== does erpnext.bundle expose SerialBatchPackageSelector? =="
grep -o "erpnext.SerialBatchPackageSelector" "$E/public/dist/js/erpnext.bundle"*.js 2>/dev/null | head -1 | sed 's/^/  /'
