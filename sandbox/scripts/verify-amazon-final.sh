#!/usr/bin/env bash
# Confirm the app is left in a clean state: no stray records, no leftovers.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend

cat > apps/amazon_integration/amazon_integration/_final.py <<'PYEOF'
import glob
import os

import frappe


def run():
    print("MARK accounts:", frappe.db.count("Amazon Account"))
    print("MARK doctype:", frappe.db.exists("DocType", "Amazon Account"))
    print("MARK module:", frappe.db.exists("Module Def", "Amazon Integration"))
    print("MARK perms:", frappe.db.count("DocPerm", {"parent": "Amazon Account"}))
    # stray helper modules in the app tree?
    app = "/home/frappe/frappe-bench/apps/amazon_integration"
    strays = [
        p for p in glob.glob(app + "/amazon_integration/**/*.py", recursive=True)
        if os.path.basename(p).startswith("_") and os.path.basename(p) != "__init__.py"
    ]
    print("MARK stray helper modules:", strays)
PYEOF
bench --site "$SITE" execute amazon_integration._final.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f apps/amazon_integration/amazon_integration/_final.py

echo
echo "== ping =="
curl -s -o /dev/null -w "  ping=%{http_code}\n" -H "Host: $SITE" http://localhost:8000/api/method/ping
