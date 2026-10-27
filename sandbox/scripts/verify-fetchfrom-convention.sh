#!/usr/bin/env bash
# Confirm the v16 child-table fetch_from convention (Read Only fieldtype +
# fetch_from) so the Car Service Record workshop fields follow core exactly.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

echo "== core child field using fetch_from (Asset Maintenance Task) =="
env/bin/python - <<'PYEOF'
import json
p = "apps/erpnext/erpnext/assets/doctype/asset_maintenance_task/asset_maintenance_task.json"
d = json.load(open(p))
for f in d["fields"]:
    if f.get("fetch_from"):
        print(json.dumps(f, indent=1))
PYEOF
