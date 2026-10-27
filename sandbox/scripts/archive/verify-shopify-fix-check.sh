#!/usr/bin/env bash
set -uo pipefail
cd /home/frappe/frappe-bench/apps/shopify/shopify || exit 1

echo "== remaining unguarded get_doc('Shopify Access' patterns =="
grep -rn 'get_doc("Shopify Access"' *.py || echo "  none (all guarded)"

echo "== files using get_shopify_access =="
grep -rln 'get_shopify_access' *.py

echo "== import check: all modules load =="
cd /home/frappe/frappe-bench || exit 1
bench --site frontend console <<'PYEOF'
import importlib
mods = ["create_product","update_product","delete_product","create_order","update_order","cancel_order","delete_order","create_customer","update_customer","delete_customer","update_product_inventory","utils"]
for m in mods:
    importlib.import_module("shopify." + m)
    print("OK import shopify." + m)
PYEOF
