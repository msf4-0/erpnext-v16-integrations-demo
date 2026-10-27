#!/usr/bin/env bash
# Find the v16 mechanism that serves a doctype's .js to the desk, and confirm the
# SERVED content includes the fix.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bpjs
mkdir -p "$J"

echo "== v16 loader for doctype js (source) =="
grep -rn "get_doctype_js\|def get_js\b\|get_js(" apps/frappe/frappe/desk/form/load.py 2>/dev/null | head -10 | sed 's/^/  /'
grep -rn "def get_js" apps/frappe/frappe/client.py 2>/dev/null | head | sed 's/^/  /'

echo
echo "== find get_doctype_js definition =="
grep -rn "def get_doctype_js" apps/frappe/frappe/ 2>/dev/null | head | sed 's/^/  /'

echo
echo "== console: rendered doctype js includes our guards? =="
cat > /tmp/_gd2.py <<'PYEOF'
import frappe
try:
    from frappe.desk.form.load import get_doctype_js
    js = get_doctype_js("Barcode Printing")
    print("MARK get_doctype_js len", len(js or ""))
except Exception as e:
    print("MARK get_doctype_js ERROR", type(e).__name__, e)
    js = ""
for needle in ("typeof item.serial_no", "erpnext.stock.utils.scan_barcode",
               "SerialBatchPackageSelector", "erpnext.setup_serial_no();"):
    print("MARK contains %-34s %s" % (needle, needle in (js or "")))
PYEOF
bench --site "$SITE" console < /tmp/_gd2.py 2>&1 | tail -12 | sed 's/^/  /'

echo
echo "== HTTP: /api/method/frappe.desk.form.load.getdoctype?doctype=Barcode Printing =="
curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o /dev/null -w "  login=%{http_code}\n"
curl -s -b "$J/jar" -H "Host: $SITE" \
  "$B/api/method/frappe.desk.form.load.getdoctype?doctype=Barcode%20Printing&with_parent=1" \
  -o "$J/gd.json" -w "  getdoctype http=%{http_code}\n"
python3 - "$J/gd.json" <<'PYEOF'
import json, sys, re
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("  (not json)", e); raise SystemExit
txt = json.dumps(d)
for needle in ("typeof item.serial_no", "erpnext.stock.utils.scan_barcode",
               "SerialBatchPackageSelector", "erpnext.setup_serial_no();",
               "__js", "barcode_printing.js"):
    print("  contains %-34s %s" % (needle, needle in txt))
# show any js file references
for m in sorted(set(re.findall(r'[A-Za-z0-9_./\-]*barcode_printing[A-Za-z0-9_.\-]*', txt))):
    print("  ref:", m)
PYEOF
