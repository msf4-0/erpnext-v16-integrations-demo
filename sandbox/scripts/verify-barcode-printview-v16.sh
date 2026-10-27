#!/usr/bin/env bash
# Render the barcode print formats server-side (as the print/PDF pipeline does)
# and report status + whether a real barcode/QR <img> is present.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bpprint
mkdir -p "$J"

cat > /tmp/_pfdoc.py <<'PYEOF'
import frappe, json
d = frappe.get_all("Barcode Printing", limit=1, pluck="name")
open("/tmp/bpprint/doc.txt","w").write(d[0] if d else "")
PYEOF
bench --site "$SITE" console < /tmp/_pfdoc.py > /dev/null 2>&1
DOC=$(cat "$J/doc.txt")
echo "doc=$DOC"

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o "$J/login" -w "login=%{http_code}\n"

for PF in "Barcode Printing Format" "Barcode Printing Format A4" "QR Code Printing Format"; do
  ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$PF")
  echo
  echo "== format: $PF =="
  curl -s -b "$J/jar" -H "Host: $SITE" \
    "$B/api/method/frappe.www.printview.get_html_and_style?doc=Barcode%20Printing&name=$DOC&print_format=$ENC&no_letterhead=1" \
    -o "$J/out.json" -w "http=%{http_code}\n"
  python3 - "$J/out.json" <<'PYEOF'
import json, sys, re
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("  (not json)", e); raise SystemExit
msg = d.get("message") or {}
html = (msg.get("html") or "")
print("  html len:", len(html))
for needle in ("<img", "jsdelivr", "JsBarcode", "<svg", "data:image", "get_barcode_image", "get_qr_image"):
    print("   contains %-18s %s" % (needle, needle in html))
for m in set(re.findall(r'/files/[A-Za-z0-9_.\-]+', html)):
    print("   file url:", m)
for exc in re.findall(r'(Traceback|Error|Exception)[^\n]*', html):
    print("   ", exc[:200])
PYEOF
done
