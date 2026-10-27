#!/usr/bin/env bash
# Map the v16 print-preview paths the BROWSER actually uses, then probe each.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bpprevmap
rm -rf "$J"; mkdir -p "$J"
F=apps/frappe/frappe

echo "== v16 print preview front-end implementation =="
grep -rln "printview\|print_preview\|PrintView\|get_html_and_style" "$F/public/js" "$F/printing" 2>/dev/null | head -20 | sed 's/^/  /'

echo
echo "== printing page assets =="
find "$F" -path '*printing*' -name '*.js' 2>/dev/null | head -20 | sed 's/^/  /'

echo
echo "== endpoints referenced for preview =="
grep -rn "get_html_and_style\|frappe.www.printview\|download_pdf\|print_format" "$F/printing" "$F/public/js/print_format*" 2>/dev/null | head -20 | sed 's/^/  /'

echo
echo "== login =="
curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o /dev/null -w "  login=%{http_code}\n"

echo
echo "== GET /printview (full page, as an iframe src) =="
curl -s -b "$J/jar" -H "Host: $SITE" \
  "$B/printview?doctype=Barcode%20Printing&name=BP-2026-09-24-00001&format=Barcode%20Printing%20Format&no_letterhead=0&trigger_print=0" \
  -o "$J/pv.html" -w "  http=%{http_code} bytes=%{size_download}\n"
python3 - "$J/pv.html" <<'PYEOF'
import sys, re
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
print("  has <img:", "<img" in h, "| /files/:", "/files/" in h,
      "| jsdelivr:", "jsdelivr" in h, "| Traceback:", "Traceback" in h)
print("  file urls:", sorted(set(re.findall(r'/files/[A-Za-z0-9_.\-]+', h)))[:5])
print("  title:", (re.findall(r'<title>([^<]*)</title>', h) or ['?'])[0])
PYEOF

echo
echo "== POST frappe.www.printview.get_html_and_style (preview modal) =="
curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/frappe.www.printview.get_html_and_style" \
  --data '{"doc":"Barcode Printing","name":"BP-2026-09-24-00001","print_format":"Barcode Printing Format"}' \
  -o "$J/ghs.json" -w "  http=%{http_code}\n"
python3 - "$J/ghs.json" <<'PYEOF'
import json, sys, re
d = json.load(open(sys.argv[1]))
if "exception" in d:
    print("  EXCEPTION:", d["exception"][:200]); raise SystemExit
html = ((d.get("message") or {}).get("html") or "")
print("  html len:", len(html), "| <img:", "<img" in html,
      "| /files/:", "/files/" in html, "| jsdelivr:", "jsdelivr" in html)
print("  file urls:", sorted(set(re.findall(r'/files/[A-Za-z0-9_.\-]+', html)))[:5])
PYEOF

echo
echo "== POST frappe.printing.page.print.print.download_pdf (PDF preview) =="
curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/frappe.utils.print_format.download_pdf" \
  --data '{"doctype":"Barcode Printing","name":"BP-2026-09-24-00001","format":"Barcode Printing Format"}' \
  -o "$J/pdf.json" -w "  http=%{http_code}\n"
head -c 400 "$J/pdf.json"; echo
