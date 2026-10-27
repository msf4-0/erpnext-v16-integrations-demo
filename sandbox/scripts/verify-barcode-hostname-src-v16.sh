#!/usr/bin/env bash
# Find how v16 get_url() picks its host, and where a resolvable host_name can be
# set (for the PDF/print-preview path).
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

echo "== get_url() source =="
grep -rn "def get_url" apps/frappe/frappe/utils/__init__.py | sed 's/^/  /'
sed -n "$(grep -n 'def get_url' apps/frappe/frappe/utils/__init__.py | head -1 | cut -d: -f1),+45p" \
  apps/frappe/frappe/utils/__init__.py | sed 's/^/  /'

echo
echo "== where is host_name read? =="
grep -rn "host_name" apps/frappe/frappe/utils/__init__.py apps/frappe/frappe/app.py 2>/dev/null | head -20 | sed 's/^/  /'

echo
echo "== System Settings / Website Settings host_name field (v16) =="
grep -rn "host_name" apps/frappe/frappe/core/doctype/system_settings/system_settings.json 2>/dev/null | head | sed 's/^/  /'
grep -rln "host_name" apps/frappe/frappe/website/doctype/website_settings/ 2>/dev/null | sed 's/^/  /'

echo
echo "== how get_print builds pdf options (base_url) =="
grep -rn "base_url" apps/frappe/frappe/utils/print_utils.py apps/frappe/frappe/utils/pdf.py apps/frappe/frappe/utils/print_format.py 2>/dev/null | head -20 | sed 's/^/  /'

echo
echo "== site_config.json keys =="
cat sites/frontend/site_config.json | sed 's/^/  /'
echo "  common host_name: $(grep -o '\"host_name\"[^,]*' sites/common_site_config.json 2>/dev/null || echo none)"
