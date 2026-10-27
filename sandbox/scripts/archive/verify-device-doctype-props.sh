#!/usr/bin/env bash
# Recon before authoring the Device doctype: confirm the v16-specific
# DocType JSON properties I plan to use actually exist on THIS version,
# instead of assuming. Specifically:
#   - "non_negative" on Float fields (newer frappe property)
#   - "precision" on Float fields
#   - "naming_rule" values
#   - the shape of a real v16 doctype with a Float field
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

echo "== is 'non_negative' a known property in v16 frappe? =="
grep -rn "non_negative" apps/frappe/frappe/model/ 2>/dev/null | head -10
echo "-- occurrences in erpnext doctype json --"
grep -rl "non_negative" apps/erpnext --include=*.json 2>/dev/null | head -5

echo
echo "== 'precision' on Float =="
grep -rn '"precision"' apps/erpnext --include=*.json 2>/dev/null | head -3

echo
echo "== a real v16 doctype with a Float field (shape reference) =="
find apps/erpnext -name '*.json' -path '*doctype*' 2>/dev/null \
  | xargs grep -l '"fieldtype": "Float"' 2>/dev/null | head -2

echo
echo "== frappe version =="
bench version
