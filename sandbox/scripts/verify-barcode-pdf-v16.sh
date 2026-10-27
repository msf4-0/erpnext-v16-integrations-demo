#!/usr/bin/env bash
# Verify the barcode print formats produce a real PDF now that host_name is
# resolvable, using the same GET the desk uses.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bppdf
mkdir -p "$J"

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o /dev/null -w "login=%{http_code}\n"

for PF in "Barcode Printing Format" "Barcode Printing Format A4" "QR Code Printing Format"; do
  ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$PF")
  curl -s -b "$J/jar" -H "Host: $SITE" \
    "$B/api/method/frappe.utils.print_format.download_pdf?doctype=Barcode%20Printing&name=BP-2026-09-24-00001&format=$ENC&no_letterhead=0" \
    -o "$J/pdf.bin" -w "  %-28s http=%{http_code} bytes=%{size_download} type=%{content_type}\n"
  python3 - "$J/pdf.bin" "$PF" <<'PYEOF'
import sys
b = open(sys.argv[1], "rb").read()
print("     %-28s magic=%r pdf=%s" % (sys.argv[2], b[:5], b[:4] == b"%PDF"))
if b[:4] != b"%PDF":
    import json
    try:
        d = json.loads(b.decode("utf-8", "replace"))
        print("     error:", (d.get("exc_type") or "")[:80], (d.get("exception") or "")[:160])
    except Exception:
        print("     raw:", b[:200])
PYEOF
done

echo
echo "== ping =="
curl -s -o /dev/null -w "  ping=%{http_code}\n" -H "Host: $SITE" "$B/api/method/ping"
