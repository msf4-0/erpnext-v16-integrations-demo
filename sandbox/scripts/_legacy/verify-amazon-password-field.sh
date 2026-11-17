#!/usr/bin/env bash
# Understand v16 'Password' fieldtype semantics + core usage, to inform the
# credential-storage recommendation.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
F=apps/frappe/frappe

echo "== the fieldtype list containing 'Password' =="
grep -n '"Password"' -B 25 "$F/model/__init__.py" | grep -E "^[0-9]+[:-]\s*(fieldtypes|#|\"|'|\])" | tail -30 | sed 's/^/  /'

echo
echo "== is Password in 'no_value_fields' / 'optional_fields'? =="
python3 - <<'PYEOF'
import re
src = open("apps/frappe/frappe/model/__init__.py", encoding="utf-8").read()
for name in ("no_value_fields", "optional_fields", "default_fields", "table_fields", "data_fieldtypes", "numeric_fieldtypes"):
    m = re.search(r"^%s\s*=\s*\[(.*?)\]" % name, src, re.S | re.M)
    if m and "Password" in m.group(1):
        print("  %s CONTAINS Password" % name)
    elif m:
        print("  %s (no Password)" % name)
    else:
        print("  %s (not a simple list)" % name)
PYEOF

echo
echo "== core doctypes that use a Password field (examples) =="
grep -rln '"fieldtype": "Password"' "$F" --include=*.json 2>/dev/null | head -10 | sed 's/^/  /'

echo
echo "== how Password values are persisted (encryption path) =="
grep -rn "Password" "$F/model/base_document.py" 2>/dev/null | head -10 | sed 's/^/  /'
grep -rn "get_encrypted\|password" "$F/utils/password.py" 2>/dev/null | head -12 | sed 's/^/  /'

echo
echo "== can a Password field be marked read_only / hidden? =="
grep -rn '"fieldtype": "Password"' -A 6 "$F" --include=*.json 2>/dev/null | grep -E "read_only|hidden" | head -5 | sed 's/^/  /'
