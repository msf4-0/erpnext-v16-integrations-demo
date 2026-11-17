#!/usr/bin/env bash
# Fix 1 — barcode_shrdc on ERPNext v16: whitelist the BarcodePrinting.get_item_details
# CLASS method.
#
# Symptom (reproduced over HTTP 403):
#   {"exception":"frappe.exceptions.PermissionError: <details><summary>You are not
#    permitted to access this resource. Login to access</summary>Function
#    barcode_shrdc...barcode_printing.get_item_details is not whitelisted.</details>"}
#
# Root cause: barcode_printing.js fetches item details with
#   frappe.call({ doc: frm.doc, method: "get_item_details", ... })
# which goes through frappe.handler.run_doc_method. Since v15 run_doc_method calls
# is_whitelisted(fn) on the controller method, and upstream master's class method
# has NO @frappe.whitelist() decorator (only the unused module-level function does).
# v16 enforces this too. Fixed by adding the decorator to the class method.
set -uo pipefail
APP=/home/frappe/frappe-bench/apps/barcode_shrdc
F="$APP/barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.py"

echo "== before =="
grep -n -B1 "def get_item_details(self" "$F"

python3 - "$F" <<'PYEOF'
import sys, io

path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()

marker = "\tdef get_item_details(self, args=None, for_update=False):"
# exact existing decorator (already applied)? then no-op
if "\t@frappe.whitelist()\n" + marker in src:
    print("ALREADY PATCHED: class method already has @frappe.whitelist()")
    sys.exit(0)

if marker not in src:
    print("ERROR: class method marker not found; aborting so we don't patch blind")
    sys.exit(1)

src = src.replace(marker, "\t@frappe.whitelist()\n" + marker, 1)
io.open(path, "w", encoding="utf-8").write(src)
print("PATCHED: added @frappe.whitelist() to the class method")
PYEOF
rc=$?

echo "== after =="
grep -n -B1 "def get_item_details(self" "$F"
exit $rc
