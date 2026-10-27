#!/usr/bin/env bash
# Verify v16 compatibility points needed by the barcode fix.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
echo "== frappe.utils.file_manager.get_files_path exists? =="
grep -rn "def get_files_path" apps/frappe/frappe/utils/file_manager.py | sed 's/^/  /'
echo
echo "== frappe.generate_hash exists? =="
grep -rn "def generate_hash" apps/frappe/frappe/__init__.py | sed 's/^/  /'
echo
echo "== jinja hook handling in frappe (methods list) =="
grep -rn '"jinja"\|jinja_methods\|jinja\.methods' apps/frappe/frappe/utils/jinja_globals.py apps/frappe/frappe/utils/*.py 2>/dev/null | head -10 | sed 's/^/  /'
echo
echo "== get_files_path / site public files layout =="
cat > /tmp/_fp.py <<'PYEOF'
import frappe
from frappe.utils.file_manager import get_files_path
print("MARK get_files_path ->", get_files_path())
print("MARK site path ->", frappe.get_site_path("public", "files"))
PYEOF
bench --site frontend console < /tmp/_fp.py 2>&1 | grep '^MARK' | sed 's/^/  /'
echo
echo "== whitelisted module fn get_item_details reachable via HTTP? =="
curl -s -o /dev/null -w "  ping=%{http_code}\n" -H "Host: frontend" http://localhost:8000/api/method/ping
