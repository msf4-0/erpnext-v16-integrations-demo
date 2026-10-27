#!/usr/bin/env bash
# Final integrity: custom fields intact, app tree clean, no stray helpers, and
# the key Barcode Printing endpoints healthy.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend

echo "== custom fields (the 5 formerly-shadowed ones must be present) =="
cat > apps/barcode_shrdc/barcode_shrdc/_cfintegrity.py <<'PYEOF'
import frappe


def run():
    want = ["Delivery Note-barcode_validation", "Delivery Note Item-checking_qty",
            "Stock Entry-stock_check", "Stock Entry Detail-checking_qty",
            "Sales Invoice Item-reference_dt", "Sales Invoice Item-reference_dn"]
    missing = [w for w in want if not frappe.db.exists("Custom Field", w)]
    print("MARK missing custom fields:", missing or "[] (all present)")
    print("MARK Barcode Shrdc custom fields:", frappe.db.count("Custom Field", {"module": "Barcode Shrdc"}))
    print("MARK Client Scripts:", frappe.db.count("Client Script"))
    # print format DB values carry the server-side renderers
    for n in ("Barcode Printing Format", "Barcode Printing Format A4", "QR Code Printing Format"):
        h = frappe.db.get_value("Print Format", n, "html") or ""
        print("MARK pf %-28s len=%d get_barcode_image=%s get_qr_image=%s jsdelivr=%s"
              % (n, len(h), "get_barcode_image" in h, "get_qr_image" in h, "jsdelivr" in h))
PYEOF
bench --site "$SITE" execute barcode_shrdc._cfintegrity.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f apps/barcode_shrdc/barcode_shrdc/_cfintegrity.py

echo
echo "== app tree: no stray helper modules =="
find apps/barcode_shrdc -name '*helper*.py' -o -name '_*.py' 2>/dev/null | grep -v '.git' | sed 's/^/  /' || true
echo "  (none listed above = clean)"

echo
echo "== git status of the app =="
( cd apps/barcode_shrdc && git status --short ) | sed 's/^/  /'

echo
echo "== ping =="
curl -s -o /dev/null -w "  ping=%{http_code}\n" -H "Host: $SITE" http://localhost:8000/api/method/ping
