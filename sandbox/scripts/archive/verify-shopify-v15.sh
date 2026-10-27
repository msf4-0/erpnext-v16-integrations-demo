#!/usr/bin/env bash
# Verify the shopify app (installed from the local fixed fork) on the current
# v15 sandbox, alongside barcode_shrdc. Checks registration, doctypes, custom
# fields, the get_shopify_access() guard, module imports, and authenticated REST.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

echo "== list-apps =="
bench --site frontend list-apps

echo "== versions =="
bench version

echo "== Shopify doctypes =="
bench --site frontend execute frappe.client.get_list --kwargs '{"doctype":"DocType","filters":{"module":"Shopify"},"fields":["name"]}'

echo "== Shopify custom fields =="
bench --site frontend execute frappe.client.get_list --kwargs '{"doctype":"Custom Field","filters":{"fieldname":["in",["shopify_product_id","shopify_order_id","shopify_customer_id"]]},"fields":["name","dt","fieldname"]}'

echo "== get_shopify_access() guard (should be None, no crash) =="
bench --site frontend execute shopify.utils.get_shopify_access

echo "== app source: guarded vs unguarded handlers =="
grep -rln 'get_shopify_access' apps/shopify/shopify/*.py
echo "-- remaining unguarded get_doc(\"Shopify Access\" inline patterns --"
grep -rn 'get_doc("Shopify Access"' apps/shopify/shopify/*.py || echo "  none"

echo "== module import check (must run under bench site context) =="
# Do NOT use bare env/bin/python: without a frappe site/DB context some
# modules raise a bogus "dev_server" error at import time (frappe get_doc()
# monkeypatches, e.g. update_order.py's DocType attach, need a live site),
# which reads as a false failure. bench execute with a helper module inside
# the installed package is the reliable, non-interactive path (bench console
# with a heredoc hangs on its In[ ] prompt instead).
cat > apps/shopify/shopify/_diag_imports.py <<'PYEOF'
import importlib, traceback

def run():
    mods = ["create_product","update_product","delete_product","create_order","update_order",
            "cancel_order","delete_order","create_customer","update_customer","delete_customer",
            "update_product_inventory","utils","api","automated_orders","retrieve_product",
            "retrieve_customer","retrieve_order"]
    bad = []
    for m in mods:
        try:
            importlib.import_module("shopify." + m)
            print("OK import shopify." + m)
        except Exception as e:
            bad.append(m)
            print("FAIL import shopify.%s -> %s: %s" % (m, type(e).__name__, e))
            traceback.print_exc()
    print("IMPORT FAILURES:", bad if bad else "none")
PYEOF
bench --site frontend execute shopify._diag_imports.run
rm -f apps/shopify/shopify/_diag_imports.py

echo "== shopify.api whitelisted methods present =="
cat > apps/shopify/shopify/_diag_api.py <<'PYEOF'
import shopify.api as api

def run():
    for fn in ("sync_retrieve_products","sync_create_products","sync_retrieve_customers",
               "upsert_item","delete_item","update_item"):
        print(("OK   " if hasattr(api, fn) else "FAIL ") + "shopify.api." + fn)
    print("api.retrieve_shopify_product ->",
          api.retrieve_shopify_product.__module__ + "." + api.retrieve_shopify_product.__name__)
PYEOF
bench --site frontend execute shopify._diag_api.run
rm -f apps/shopify/shopify/_diag_api.py

echo "== REST: login =="
curl -s -c /tmp/c.txt -H "Host: frontend" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' http://localhost:8000/api/method/login > /dev/null

echo "== REST: Shopify Access =="
curl -s -b /tmp/c.txt -H "Host: frontend" -o /dev/null -w "HTTP %{http_code}\n" \
  "http://localhost:8000/api/resource/Shopify%20Access?limit_page_length=1"

echo "== REST: Shopify Link =="
curl -s -b /tmp/c.txt -H "Host: frontend" -o /dev/null -w "HTTP %{http_code}\n" \
  "http://localhost:8000/api/resource/Shopify%20Link?limit_page_length=1"

echo "== REST: Barcode Printing (regression check) =="
curl -s -b /tmp/c.txt -H "Host: frontend" -o /dev/null -w "HTTP %{http_code}\n" \
  "http://localhost:8000/api/resource/Barcode%20Printing?limit_page_length=1"

echo "== REST: ping =="
curl -s -o /dev/null -w "HTTP %{http_code}\n" -H "Host: frontend" \
  "http://localhost:8000/api/method/ping"
