#!/usr/bin/env bash
# Establish the CURRENT state of barcode_shrdc on this v16 sandbox:
#  - version
#  - whitelist status of the class vs module-level get_item_details
#  - which erpnext serial APIs the JS references actually exist in v16
# Read-only. Runs INSIDE the bench container.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
E=/home/frappe/frappe-bench/apps/erpnext/erpnext

echo "== bench version =="
bench version 2>/dev/null | sed 's/^/  /'

echo
echo "== python: whitelist sets + dead-API import checks =="
cat > /tmp/_state.py <<'PYEOF'
import importlib, traceback
import frappe
from frappe import whitelisted

def mark(msg):
    print("MARK", msg)

BPP = "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing"
try:
    m = importlib.import_module(BPP)
    mark("module import: OK")
    mark("class method BarcodePrinting.get_item_details whitelisted: %s"
         % (getattr(m.BarcodePrinting, "get_item_details") in whitelisted))
    mark("module fn get_item_details whitelisted: %s"
         % (m.get_item_details in whitelisted))
except Exception as e:
    mark("module import ERROR: %r" % e)

# erpnext APIs the JS calls
for path in (
    "erpnext.stock.get_item_details.get_serial_no",
    "erpnext.stock.get_item_details.get_item_code",
    "erpnext.stock.doctype.stock_entry.stock_entry.get_uom_details",
    "erpnext.stock.utils.get_incoming_rate",
):
    mod, fn = path.rsplit(".", 1)
    try:
        f = getattr(importlib.import_module(mod), fn)
        mark("py %-55s exists whitelisted=%s" % (path, f in whitelisted))
    except Exception as e:
        mark("py %-55s LOAD ERROR: %s" % (path, type(e).__name__))

# inspect the get_serial_no stub body
try:
    import inspect
    from erpnext.stock.get_item_details import get_serial_no
    src = inspect.getsource(get_serial_no)
    mark("get_serial_no source:\n" + src)
except Exception as e:
    mark("get_serial_no inspect ERROR: %r" % e)
PYEOF
bench --site "$SITE" console < /tmp/_state.py 2>&1 | grep -E '^MARK|Error|Traceback' | sed 's/^/  /'

echo
echo "== erpnext JS globals referenced by the app =="
for sym in "erpnext.setup_serial_no" "erpnext.stock.StockController" \
           "erpnext.stock.select_batch_and_serial_no" \
           "erpnext.SerialNoBatchSelector" "erpnext.SerialBatchPackageSelector"; do
  n=$(grep -rn --include=*.js -F "$sym" "$E/public" "$E/stock" 2>/dev/null | wc -l)
  echo "  MARK $sym -> $n occurrences"
done

echo
echo "== app .js: current guards present? =="
JS=/home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.js
for needle in 'serial_no.split' 'setup_serial_no' 'SerialNoBatchSelector' \
              'typeof serials' 'typeof item.serial_no'; do
  n=$(grep -c -F "$needle" "$JS" 2>/dev/null || true)
  echo "  MARK js '$needle' -> $n"
done

echo
echo "== site ping =="
curl -s -o /dev/null -w "  ping=%{http_code}\n" -H "Host: $SITE" http://localhost:8000/api/method/ping
