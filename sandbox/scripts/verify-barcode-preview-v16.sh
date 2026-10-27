#!/usr/bin/env bash
# Reproduce BOTH preview paths for the Barcode Printing print formats:
#   A) the desk Print Preview route  /printview?doctype=..&name=..&format=..
#   B) the form's own "Preview:" sections (client-side; need JsBarcode)
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bpprev
rm -rf "$J"; mkdir -p "$J"

cat > /home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc/_prevseed.py <<'PYEOF'
import frappe


def run():
    d = frappe.get_doc("Barcode Printing", "BP-2026-09-24-00001")
    d.show_sku = 1
    d.show_serial_no = 0
    d.show_batch_no = 0
    for r in d.items:
        if not r.barcode:
            r.barcode = "123456789012"
            r.barcode_type = "EAN13"
        if not r.rate:
            r.rate = 9.5
    d.flags.ignore_validate_update_after_submit = True
    d.save(ignore_permissions=True)
    frappe.db.commit()
    print("MARK doc", d.name, "show_sku", d.show_sku, "show_serial_no", d.show_serial_no)
PYEOF
bench --site "$SITE" execute barcode_shrdc._prevseed.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f /home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc/_prevseed.py

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o /dev/null -w "login=%{http_code}\n"

echo
echo "== A) desk Print Preview route /printview =="
for PF in "Barcode%20Printing%20Format" "Barcode%20Printing%20Format%20A4" "QR%20Code%20Printing%20Format"; do
  curl -s -b "$J/jar" -H "Host: $SITE" \
    "$B/printview?doctype=Barcode%20Printing&name=BP-2026-09-24-00001&format=$PF&no_letterhead=0" \
    -o "$J/pv.html" -w "  $PF http=%{http_code} bytes=%{size_download}\n"
  python3 - "$J/pv.html" <<'PYEOF'
import sys, re
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
imgs = re.findall(r'<img[^>]+>', h)
files = sorted(set(re.findall(r'/files/[A-Za-z0-9_.\-]+', h)))
print("     imgs=%d jsdelivr=%s <svg=%s datauri=%s" % (len(imgs), "jsdelivr" in h, "<svg" in h, "data:image" in h))
for f in files[:5]:
    print("     file url:", f)
for exc in re.findall(r'(Traceback|UndefinedError|PrintFormatError)[^\n<]*', h)[:3]:
    print("     ", exc[:160])
PYEOF
done

echo
echo "== B) is jsdelivr reachable (the form previews need it client-side)? =="
curl -s -o /dev/null -w "  cdn.jsdelivr.net -> %{http_code} (%{time_total}s)\n" --max-time 8 \
  https://cdn.jsdelivr.net/npm/jsbarcode@3.11.0/dist/JsBarcode.all.min.js || echo "  jsdelivr UNREACHABLE from container"

echo
echo "== C) does the app ship JsBarcode locally? =="
find apps/barcode_shrdc -iname '*jsbarcode*' 2>/dev/null | grep -v '.git' | sed 's/^/  /' || true
ls -la sites/assets/barcode_shrdc/js/ 2>/dev/null | sed 's/^/  /' || echo "  no assets/barcode_shrdc/js"

echo
echo "== D) ping =="
curl -s -o /dev/null -w "  ping=%{http_code}\n" -H "Host: $SITE" "$B/api/method/ping"
