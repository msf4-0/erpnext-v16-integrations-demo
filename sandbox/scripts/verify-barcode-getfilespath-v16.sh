#!/usr/bin/env bash
# Verify the exact import path for get_files_path on v16, and the site public
# files dir, so the fix uses the correct import.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
echo "== def get_files_path locations =="
grep -rn "def get_files_path" apps/frappe/frappe/ 2>/dev/null | sed 's/^/  /'
echo
echo "== import from frappe.utils.file_manager (fork uses this) =="
env/bin/python - <<'PYEOF'
try:
    from frappe.utils.file_manager import get_files_path
    print("  file_manager import: OK")
except Exception as e:
    print("  file_manager import FAILED:", type(e).__name__, e)
try:
    from frappe.utils import get_files_path
    print("  frappe.utils import: OK")
except Exception as e:
    print("  frappe.utils import FAILED:", type(e).__name__, e)
PYEOF
echo
echo "== get_files_path output =="
cat > /tmp/_fp2.py <<'PYEOF'
import frappe
from frappe.utils import get_files_path
print("MARK get_files_path ->", get_files_path())
print("MARK site public/files ->", frappe.get_site_path("public", "files"))
PYEOF
bench --site frontend console < /tmp/_fp2.py 2>&1 | grep '^MARK' | sed 's/^/  /'
echo
echo "== frappe.create_folder exists? =="
grep -rn "def create_folder" apps/frappe/frappe/__init__.py | sed 's/^/  /'
