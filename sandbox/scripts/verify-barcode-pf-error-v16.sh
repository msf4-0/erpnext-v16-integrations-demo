#!/usr/bin/env bash
# Capture the exact 417 error from the print-view render after the durability
# reset+reapply, to see whether the jinja hook / renderer is broken.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bperr
mkdir -p "$J"

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o /dev/null -w "login=%{http_code}\n"

echo
echo "== get_html_and_style for Barcode Printing Format =="
curl -s -b "$J/jar" -H "Host: $SITE" \
  "$B/api/method/frappe.www.printview.get_html_and_style?doc=Barcode%20Printing&name=BP-2026-09-24-00001&print_format=Barcode%20Printing%20Format&no_letterhead=1" \
  -o "$J/out.json" -w "http=%{http_code}\n"
head -c 2000 "$J/out.json"; echo

echo
echo "== direct jinja render via bench execute (app helper) =="
cat > apps/barcode_shrdc/barcode_shrdc/_rerrtest.py <<'PYEOF'
import frappe


def run():
    doc = frappe.get_doc("Barcode Printing", "BP-2026-09-24-00001")
    for name in ("Barcode Printing Format", "QR Code Printing Format"):
        try:
            html = frappe.get_doc("Print Format", name).get_html(doc, no_letterhead=1)
            print("MARK", name, "len", len(html), "imgs", html.count("<img"))
        except Exception as e:
            import traceback
            print("MARK", name, "ERROR", type(e).__name__, e)
            traceback.print_exc()
PYEOF
bench --site "$SITE" execute barcode_shrdc._rerrtest.run 2>&1 | tail -40 | sed 's/^/  /'
rm -f apps/barcode_shrdc/barcode_shrdc/_rerrtest.py

echo
echo "== is the jinja hook registered? =="
cat > apps/barcode_shrdc/barcode_shrdc/_jinjacheck.py <<'PYEOF'
import frappe
from frappe.utils.jinja import get_jenv, get_jinja_hooks


def run():
    try:
        methods, filters = get_jinja_hooks()
        print("MARK jinja methods keys:", sorted(methods.keys()))
    except Exception as e:
        print("MARK get_jinja_hooks ERROR", type(e).__name__, e)
    hooks = frappe.get_hooks("jinja")
    print("MARK raw jinja hook:", hooks)
PYEOF
bench --site "$SITE" execute barcode_shrdc._jinjacheck.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f apps/barcode_shrdc/barcode_shrdc/_jinjacheck.py
