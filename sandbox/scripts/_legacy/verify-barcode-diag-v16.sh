#!/usr/bin/env bash
# Diagnose the barcode_shrdc Barcode Printing errors on ERPNext v16.
# Read-only: inspects DB state + probes the failing code paths.
# Runs INSIDE the bench container.
set -uo pipefail
SITE=frontend
cd /home/frappe/frappe-bench || exit 1

echo "== which erpnext serial APIs exist in v16 =="
grep -rn "def setup_serial_no" /home/frappe/frappe-bench/apps/erpnext/erpnext --include=*.py || echo "MARK erpnext.setup_serial_no: ABSENT"
grep -rn "class SerialNoBatchSelector\|class SerialBatchPackageSelector" /home/frappe/frappe-bench/apps/erpnext/erpnext --include=*.py || echo "MARK no selector class found"

echo
echo "== DB probe =="
cat > /tmp/_diag.py <<'PYEOF'
import frappe
print("MARK companies:", frappe.db.count("Company"))
print("MARK items:", frappe.db.count("Item"))
print("MARK barcode_printing docs:", frappe.db.count("Barcode Printing"))
print("MARK barcode_config doctype:", frappe.db.exists("DocType","Barcode Configuration"))
print("MARK qr config doc exists:", frappe.db.exists("QR Code Configuration"))
try:
    d = frappe.get_doc("QR Code Configuration")
    print("MARK QR config:", {k: d.get(k) for k in ("border","fill","background","logo")})
except Exception as e:
    print("MARK QR config error:", type(e).__name__, e)
print("MARK client scripts:", frappe.db.count("Client Script"))
print("MARK print formats:", frappe.db.count("Print Format"))
for pf in frappe.get_all("Print Format", filters={"module":"Barcode Shrdc"}, fields=["name","doc_type"]):
    print("MARK print format:", pf.name, "|", pf.doc_type)
print("MARK cf module Barcode Shrdc:", frappe.db.count("Custom Field", {"module":"Barcode Shrdc"}))
for cf in frappe.get_all("Custom Field", filters={"fieldname":["in",["barcode_validation","stock_check","checking_qty","reference_dt","reference_dn"]]}, fields=["name"]):
    print("MARK cf:", cf.name)
from frappe import whitelisted
from barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing import BarcodePrinting
print("MARK class method in whitelisted set:", BarcodePrinting.get_item_details in whitelisted)
PYEOF
bench --site "$SITE" console < /tmp/_diag.py 2>&1 | grep -E '^MARK|Error|Traceback'

echo
echo "== app file: class-level decorators =="
grep -n -B2 "def get_item_details" /home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.py

echo
echo "== site ping =="
curl -s -o /dev/null -w "ping: %{http_code}\n" -H "Host: $SITE" http://localhost:8000/api/method/ping
