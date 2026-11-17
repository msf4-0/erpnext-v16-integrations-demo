#!/usr/bin/env bash
# Confirm the barcode v16 fixes are still present in the running container.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
A=apps/barcode_shrdc/barcode_shrdc

echo "== python controller markers =="
PY="$A/barcode_shrdc/doctype/barcode_printing/barcode_printing.py"
grep -n "def get_barcode_image\|def get_qr_image\|def _save_public_image\|Please save the document before\|frappe.parse_json(frm)" "$PY" | sed 's/^/  /'

echo
echo "== class-method whitelist =="
grep -n -B1 "def get_item_details(self" "$PY" | sed 's/^/  /'

echo
echo "== hooks.py jinja =="
grep -n "jinja = {" -A 6 "$A/hooks.py" | sed 's/^/  /'

echo
echo "== js markers =="
JS="$A/barcode_shrdc/doctype/barcode_printing/barcode_printing.js"
grep -n "typeof item.serial_no\|typeof r.message\|scan_barcode\|SerialBatchPackageSelector\|setup_serial_no" "$JS" | sed 's/^/  /'

echo
echo "== leftover helper modules in app tree (to remove) =="
ls "$A"/*helper*.py 2>/dev/null | sed 's/^/  /' || echo "  (none)"

echo
echo "== render deps =="
env/bin/pip list 2>/dev/null | grep -iE 'reportlab|rlpycairo' | sed 's/^/  /'

echo
echo "== print format DB state =="
cat > /tmp/_pfstate.py <<'PYEOF'
import frappe
for n in ("Barcode Printing Format", "Barcode Printing Format A4", "QR Code Printing Format"):
    h = frappe.db.get_value("Print Format", n, "html") or ""
    print("MARK", n, "| len", len(h), "| jsdelivr", "jsdelivr" in h,
          "| get_barcode_image", "get_barcode_image" in h, "| get_qr_image", "get_qr_image" in h)
PYEOF
bench --site frontend console < /tmp/_pfstate.py 2>&1 | grep '^MARK' | sed 's/^/  /'

echo
echo "== ping =="
curl -s -o /dev/null -w "  ping=%{http_code}\n" -H 'Host: frontend' http://localhost:8000/api/method/ping
