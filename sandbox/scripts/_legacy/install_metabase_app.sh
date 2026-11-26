#!/bin/bash
set -e
cd /home/frappe/frappe-bench

SP=$(dirname "$(find env -name 'frappe.pth' -print -quit)")
printf '/home/frappe/frappe-bench/apps/metabase_integration\n' > "$SP/metabase_integration.pth"

grep -q '^metabase_integration$' sites/apps.txt || echo 'metabase_integration' >> sites/apps.txt

echo '--- apps.txt ---'
cat sites/apps.txt
echo '--- pth ---'
ls -la "$SP"/metabase_integration.pth

echo '--- migrate ---'
bench --site frontend migrate
