#!/usr/bin/env bash
# Inspect why the barcode print formats render almost nothing on v16.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend

cat > /tmp/_chk_sku.py <<'PYEOF'
import frappe
docname = open("/tmp/bppf/doc.txt").read().strip()
d = frappe.get_doc("Barcode Printing", docname)
print("MARK doc", d.name)
print("MARK show_sku", d.show_sku, "show_serial_no", d.show_serial_no, "show_batch_no", d.show_batch_no)
print("MARK n_items", len(d.items))
for r in d.items:
    print("MARK row", repr(r.item_code), repr(r.barcode), repr(r.barcode_type), repr(r.rate), repr(r.qty))
for name in ("Barcode Printing Format", "Barcode Printing Format A4", "QR Code Printing Format"):
    pf = frappe.get_doc("Print Format", name)
    h = pf.html or ""
    print("MARK pf", name, "len", len(h), "show_sku_in_html", "doc.show_sku" in h,
          "get_barcode_image", "get_barcode_image" in h, "get_qr_image", "get_qr_image" in h)
PYEOF
bench --site "$SITE" console < /tmp/_chk_sku.py 2>&1 | grep '^MARK' | sed 's/^/  /'

echo
echo "== render the 3 formats directly with jinja to stderr-capture exceptions =="
cat > /tmp/_chk_render.py <<'PYEOF'
import frappe
docname = open("/tmp/bppf/doc.txt").read().strip()
d = frappe.get_doc("Barcode Printing", docname)
for name in ("Barcode Printing Format", "Barcode Printing Format A4", "QR Code Printing Format"):
    try:
        html = frappe.get_doc("Print Format", name).get_html(d)
        print("MARK rendered", name, "len", len(html), "imgs", html.count("<img"))
        if "get_barcode_image" in html:
            print("MARK  WARN unresolved jinja in", name)
    except Exception as e:
        import traceback
        print("MARK render ERROR", name, type(e).__name__, e)
PYEOF
bench --site "$SITE" console < /tmp/_chk_render.py 2>&1 | grep '^MARK' | sed 's/^/  /'
