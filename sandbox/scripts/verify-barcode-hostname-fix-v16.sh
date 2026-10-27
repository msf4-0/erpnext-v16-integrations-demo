#!/usr/bin/env bash
# Try to fix the PDF/print-preview HostNotFoundError by setting a resolvable
# host_name, then verify PDF generation actually works and the browser-facing
# HTML preview is unaffected (it uses relative /files urls).
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bphost
mkdir -p "$J"

echo "== before: get_url / developer_mode / ports =="
cat > apps/barcode_shrdc/barcode_shrdc/_h1.py <<'PYEOF'
import frappe
from frappe.utils import get_url
c = frappe.conf
print("MARK get_url:", get_url())
print("MARK host_name:", c.get("host_name"), "| hostname:", c.get("hostname"))
print("MARK developer_mode:", c.get("developer_mode"), "| webserver_port:", c.get("webserver_port"), "| http_port:", c.get("http_port"))
PYEOF
bench --site "$SITE" execute barcode_shrdc._h1.run 2>&1 | grep '^MARK' | sed 's/^/  /'
rm -f apps/barcode_shrdc/barcode_shrdc/_h1.py

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o /dev/null -w "login=%{http_code}\n"

echo
echo "== before: download_pdf =="
curl -s -b "$J/jar" -H "Host: $SITE" -X POST "$B/api/method/frappe.utils.print_format.download_pdf" \
  --data '{"doctype":"Barcode Printing","name":"BP-2026-09-24-00001","format":"Barcode Printing Format"}' \
  -o "$J/pdf0.json" -w "  http=%{http_code}\n"
head -c 120 "$J/pdf0.json"; echo

echo
echo "== set host_name=http://localhost:8000 in site_config.json =="
bench --site "$SITE" set-config host_name "http://localhost:8000"
grep -o '"host_name"[^,}]*' sites/$SITE/site_config.json | sed 's/^/  /'
bench --site "$SITE" clear-cache >/dev/null 2>&1
pkill -f 'frappe serve' 2>/dev/null || true; pkill -f 'bench serve' 2>/dev/null || true; sleep 3
( cd /home/frappe/frappe-bench && setsid nohup bench serve --port 8000 > /tmp/bench-serve.log 2>&1 < /dev/null & disown )
for i in $(seq 1 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SITE" "$B/api/method/ping" || true)" = "200" ] && { echo "  serve up (${i}s)"; break; }
  sleep 1
done

echo
echo "== after: get_url =="
cat > apps/barcode_shrdc/barcode_shrdc/_h2.py <<'PYEOF'
import frappe
from frappe.utils import get_url
print("MARK get_url:", get_url())
print("MARK get_url('/files/x.png'):", get_url("/files/x.png"))
PYEOF
bench --site "$SITE" execute barcode_shrdc._h2.run 2>&1 | grep '^MARK' | sed 's/^/  /'
rm -f apps/barcode_shrdc/barcode_shrdc/_h2.py

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o /dev/null -w "  login=%{http_code}\n"

echo
echo "== after: download_pdf =="
curl -s -b "$J/jar" -H "Host: $SITE" -X POST "$B/api/method/frappe.utils.print_format.download_pdf" \
  --data '{"doctype":"Barcode Printing","name":"BP-2026-09-24-00001","format":"Barcode Printing Format"}' \
  -o "$J/pdf1.bin" -w "  http=%{http_code} bytes=%{size_download} type=%{content_type}\n"
head -c 8 "$J/pdf1.bin" | xxd 2>/dev/null | head -1 | sed 's/^/  magic: /' || true

echo
echo "== after: browser-facing HTML preview still uses RELATIVE /files urls =="
curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/frappe.www.printview.get_html_and_style" \
  --data '{"doc":"Barcode Printing","name":"BP-2026-09-24-00001","print_format":"Barcode Printing Format"}' \
  -o "$J/ghs.json" -w "  http=%{http_code}\n"
python3 - "$J/ghs.json" <<'PYEOF'
import json, re, sys
d = json.load(open(sys.argv[1]))
h = ((d.get("message") or {}).get("html") or "")
print("  html len:", len(h), "| <img:", "<img" in h)
print("  urls:", sorted(set(re.findall(r'(?:https?://[^"\' ]+)?/files/[A-Za-z0-9_.\-]+', h))))
PYEOF
