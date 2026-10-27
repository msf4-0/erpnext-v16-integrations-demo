#!/usr/bin/env bash
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
cat > /tmp/import_check.py <<'PYEOF'
import importlib
mods = ["create_product","update_product","delete_product","create_order","update_order","cancel_order","delete_order","create_customer","update_customer","delete_customer","update_product_inventory","utils"]
for m in mods:
    importlib.import_module("shopify." + m)
    print("OK import shopify." + m)
print("ALL IMPORTS OK")
PYEOF
env/bin/python /tmp/import_check.py
