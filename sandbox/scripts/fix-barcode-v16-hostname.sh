#!/usr/bin/env bash
# barcode_shrdc on v16 — make the print/PDF preview work.
#
# Symptom: opening the desk print preview (or "Download PDF") for a Barcode
# Printing format failed with
#   OSError: wkhtmltopdf reported an error: Exit with code 1 due to network
#   error: HostNotFoundError
# Root cause: frappe.get_url() resolves to the site's own name
# (http://frontend) because site_config.json has no host_name. Frappe's
# scrub_urls() expands the print format's relative /files/*.png <img> src to
# that absolute URL, and the LOCAL wkhtmltopdf process cannot resolve the
# container hostname 'frontend', so the image fetch fails and the whole PDF
# render aborts.
#
# Fix: set a host_name the local wkhtmltopdf can resolve. On this sandbox the
# site is served on container port 8000 (host port 8001 maps to it), so
# http://localhost:8000 is reachable from inside the container and is also what
# the browser uses via the port mapping.
#
# This affects ANY doctype's PDF export on this site, not just barcode — it is a
# sandbox-site configuration fix, applied here because the barcode print formats
# are the ones under test. It is idempotent. Override with HOST_URL if the
# sandbox is reached on a different host/port.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
HOST_URL="${HOST_URL:-http://localhost:8000}"

echo "== current host_name =="
grep -o '"host_name"[^,}]*' "sites/$SITE/site_config.json" 2>/dev/null | sed 's/^/  /' || echo "  (none set)"

echo
echo "== set host_name=$HOST_URL =="
bench --site "$SITE" set-config host_name "$HOST_URL" && echo "  set-config OK"
grep -o '"host_name"[^,}]*' "sites/$SITE/site_config.json" | sed 's/^/  /'

echo
echo "== confirm get_url resolves =="
cat > apps/barcode_shrdc/barcode_shrdc/_hostfix.py <<'PYEOF'
import frappe
from frappe.utils import get_url


def run():
    print("MARK get_url:", get_url())
    print("MARK get_url('/files/x.png'):", get_url("/files/x.png"))
PYEOF
bench --site "$SITE" execute barcode_shrdc._hostfix.run 2>&1 | grep '^MARK' | sed 's/^/  /'
rm -f apps/barcode_shrdc/barcode_shrdc/_hostfix.py

echo
echo "== clear cache + restart serve =="
bench --site "$SITE" clear-cache >/dev/null 2>&1 || true
pkill -f 'frappe serve' 2>/dev/null || true
pkill -f 'bench serve' 2>/dev/null || true
sleep 3
( cd /home/frappe/frappe-bench && setsid nohup bench serve --port 8000 > /tmp/bench-serve.log 2>&1 < /dev/null & disown )
for i in $(seq 1 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SITE" http://localhost:8000/api/method/ping || true)" = "200" ] \
    && { echo "  serve up after ${i}s (ping 200)"; break; }
  sleep 1
done
