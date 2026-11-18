#!/usr/bin/env bash
# Confirm the generated PDFs actually EMBED the barcode/QR image (not blank).
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bppdfimg
mkdir -p "$J"

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o /dev/null -w "login=%{http_code}\n"

for PF in "Barcode Printing Format" "QR Code Printing Format"; do
  ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$PF")
  SAFE=$(echo "$PF" | tr ' ' '_')
  curl -s -b "$J/jar" -H "Host: $SITE" \
    "$B/api/method/frappe.utils.print_format.download_pdf?doctype=Barcode%20Printing&name=BP-2026-09-24-00001&format=$ENC&no_letterhead=0" \
    -o "$J/$SAFE.pdf" -w "  %-28s bytes=%{size_download}\n" 2>/dev/null || true
  curl -s -b "$J/jar" -H "Host: $SITE" \
    "$B/api/method/frappe.utils.print_format.download_pdf?doctype=Barcode%20Printing&name=BP-2026-09-24-00001&format=$ENC&no_letterhead=0" \
    -o "$J/$SAFE.pdf" >/dev/null 2>&1
done

echo
echo "== PDF image XObjects =="
env/bin/python - "$J" <<'PYEOF'
import os, re, sys
try:
    from pypdf import PdfReader
except Exception:
    from PyPDF2 import PdfReader
d = sys.argv[1]
for f in sorted(os.listdir(d)):
    if not f.endswith(".pdf"):
        continue
    path = os.path.join(d, f)
    r = PdfReader(path)
    n_images = 0
    n_pages = len(r.pages)
    for page in r.pages:
        try:
            n_images += len(list(page.images))
        except Exception:
            pass
    print("  %-30s pages=%d embedded_images=%d" % (f, n_pages, n_images))
PYEOF

echo
echo "== extract a raw image stream check (PDF has an image XObject?) =="
for f in "$J"/*.pdf; do
  n=$(grep -a -c "/Subtype */Image" "$f" 2>/dev/null || echo 0)
  echo "  $(basename "$f"): /Subtype /Image occurrences = $n"
done
