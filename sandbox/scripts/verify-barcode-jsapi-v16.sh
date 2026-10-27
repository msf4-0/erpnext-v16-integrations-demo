#!/usr/bin/env bash
# Check which erpnext JS globals/methods the barcode app references exist in v16.
set -uo pipefail
E=/home/frappe/frappe-bench/apps/erpnext/erpnext
echo "== erpnext JS globals =="
for sym in "erpnext.setup_serial_no" "erpnext.stock.StockController" "erpnext.stock.select_batch_and_serial_no" "erpnext.SerialNoBatchSelector" "erpnext.SerialBatchPackageSelector"; do
  n=$(grep -rn --include=*.js --include=*.bundle.js -F "$sym" "$E/public" "$E/stock" 2>/dev/null | wc -l)
  echo "MARK $sym -> $n occurrences"
done

echo
echo "== python whitelisted methods referenced by JS =="
cat > /tmp/_wl.py <<'PYEOF'
import frappe
from frappe import whitelisted
targets = [
    "erpnext.stock.get_item_details.get_serial_no",
    "erpnext.stock.get_item_details.get_item_code",
    "erpnext.stock.doctype.stock_entry.stock_entry.get_uom_details",
    "erpnext.stock.utils.get_incoming_rate",
]
import importlib
def load(path):
    mod, func = path.rsplit(".", 1)
    m = importlib.import_module(mod)
    return getattr(m, func)
for t in targets:
    try:
        f = load(t)
        print("MARK", t, "-> exists, whitelisted:", f in whitelisted)
    except Exception as e:
        print("MARK", t, "-> LOAD ERROR:", type(e).__name__, e)
PYEOF
bench --site frontend console < /tmp/_wl.py 2>&1 | grep '^MARK'

echo
echo "== StockController / select_batch_and_serial_no definitions =="
grep -rn "erpnext.stock.StockController\s*=" "$E/public/js/controllers/stock_controller.js" 2>/dev/null | head
grep -rn "select_batch_and_serial_no" "$E/public/js/utils.js" 2>/dev/null | head
