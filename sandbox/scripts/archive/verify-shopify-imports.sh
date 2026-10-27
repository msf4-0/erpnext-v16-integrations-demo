#!/usr/bin/env bash
# Diagnose shopify module imports under real bench site context.
# `bench console` with a heredoc hangs on its IPython prompt, so instead we
# drop a small helper module inside the installed shopify package and call it
# via `bench --site frontend execute` (the documented non-interactive path).
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

cat > apps/shopify/shopify/_diag_imports.py <<'PYEOF'
import frappe, traceback, importlib

def run():
    mods = ["create_product","update_product","delete_product","create_order","update_order",
            "cancel_order","delete_order","create_customer","update_customer","delete_customer",
            "update_product_inventory","utils","api","automated_orders","retrieve_product",
            "retrieve_customer","retrieve_order"]
    for m in mods:
        try:
            importlib.import_module("shopify." + m)
            print("OK   shopify." + m)
        except Exception as e:
            print("FAIL shopify.%s -> %s: %s" % (m, type(e).__name__, e))
            traceback.print_exc()
PYEOF

bench --site frontend execute shopify._diag_imports.run
rm -f apps/shopify/shopify/_diag_imports.py
