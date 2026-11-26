#!/usr/bin/env bash
# Diagnose the HostNotFoundError: what does frappe.get_url() resolve to, and is
# there a resolvable host_name we can set?
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000

echo "== container hostname =="
hostname | sed 's/^/  /'
echo "  /etc/hosts:"; sed 's/^/    /' /etc/hosts

echo
echo "== frappe.get_url() resolution =="
cat > apps/barcode_shrdc/barcode_shrdc/_urlcheck.py <<'PYEOF'
import frappe
from frappe.utils import get_url
print("MARK get_url() ->", get_url())
print("MARK get_url('/files/x.png') ->", get_url("/files/x.png"))
print("MARK host_name (System Settings) ->", frappe.db.get_single_value("System Settings", "host_name"))
PYEOF
bench --site "$SITE" execute barcode_shrdc._urlcheck.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f apps/barcode_shrdc/barcode_shrdc/_urlcheck.py

echo
echo "== common_site_config / site_config host_name =="
grep -i "host_name" sites/common_site_config.json sites/frontend/site_config.json 2>/dev/null | sed 's/^/  /' || echo "  (no host_name set)"

echo
echo "== can wkhtmltopdf resolve the container hostname? =="
getent hosts frontend 2>/dev/null | sed 's/^/  /' || echo "  'frontend' NOT resolvable inside the container"
command -v wkhtmltopdf >/dev/null && wkhtmltopdf --version 2>&1 | head -1 | sed 's/^/  /'

echo
echo "== what the print-format <img> URL looks like in the DB html =="
grep -o 'src="[^"]*get_barcode_image[^"]*"' apps/barcode_shrdc/barcode_shrdc/fixtures/print_format.json 2>/dev/null | head -2 | sed 's/^/  /'

echo
echo "== ping =="
curl -s -o /dev/null -w "  ping=%{http_code}\n" -H "Host: $SITE" "$B/api/method/ping"
