#!/usr/bin/env bash
# Show the site's installed_apps and reset the amazon_integration install so we
# can reproduce the nesting trap against the HARDENED installer.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
echo "== installed_apps before =="
env/bin/python - <<'PYEOF'
import json
c = json.load(open("sites/frontend/site_config.json"))
print(" ", c.get("installed_apps"))
PYEOF
