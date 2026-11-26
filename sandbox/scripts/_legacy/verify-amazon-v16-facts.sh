#!/usr/bin/env bash
# Verify v16 specifics the Amazon-account plan depends on.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

echo "== Password fieldtype exists in v16? =="
grep -rn "Password" apps/frappe/frappe/model/__init__.py 2>/dev/null | head -3 | sed 's/^/  /'
grep -rn "fieldtype.*Password" apps/frappe/frappe/model/document.py 2>/dev/null | head -3 | sed 's/^/  /'
python3 - <<'PYEOF'
import re
src = open("apps/frappe/frappe/model/meta.py", encoding="utf-8").read()
print("  meta.py mentions Password:", "Password" in src)
PYEOF

echo
echo "== new-app wizard prompt count (this image) =="
grep -n "def _get_user_inputs" -A 60 apps/frappe/frappe/utils/boilerplate.py 2>/dev/null | grep -E "title=|prompt|click\." | head -25 | sed 's/^/  /'

echo
echo "== does a 'Password' docfield type get validated? =="
grep -rn "def validate_password\|password.*fieldtype\|fieldtype == .Password" apps/frappe/frappe/model/*.py apps/frappe/frappe/utils/*.py 2>/dev/null | head -6 | sed 's/^/  /'

echo
echo "== Select field: is there a limit? (options count) =="
grep -rn "def validate_select" -A 20 apps/frappe/frappe/model/document.py 2>/dev/null | head -25 | sed 's/^/  /'
