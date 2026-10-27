#!/usr/bin/env bash
# Fix the "Shopify Access None not found" error in the shopify app.
#
# Root cause: every handler does
#   frappe.get_doc("Shopify Access", frappe.get_value("Shopify Access", {}, "name"))
# When no Shopify Access record is configured, get_value returns None and
# get_doc("Shopify Access", None) throws "Shopify Access None not found",
# which breaks unrelated operations (e.g. creating an Item fires
# Item.after_insert -> shopify.create_product.after_insert).
#
# Fix: add a shared helper shopify.utils.get_shopify_access() that returns
# None when no record exists, and guard each handler to skip the sync when
# it returns None. This makes the app degrade gracefully when Shopify is
# not configured instead of crashing.
#
# Run inside the bench container:
#   docker compose -p erpnext-sandbox cp ./sandbox/scripts/verify-shopify-fix.sh \
#     bench:/tmp/scripts/verify-shopify-fix.sh
#   docker compose -p erpnext-sandbox exec bench bash -lc "bash /tmp/scripts/verify-shopify-fix.sh"

set -uo pipefail
APP_DIR="/home/frappe/frappe-bench/apps/shopify/shopify"
BENCH_DIR="/home/frappe/frappe-bench"

echo "== Creating shopify/utils.py helper =="
cat > "$APP_DIR/utils.py" <<'PYEOF'
import frappe

def get_shopify_access():
    """Return the first Shopify Access doc, or None if none is configured.

    The app previously did frappe.get_doc('Shopify Access',
    frappe.get_value('Shopify Access', {}, 'name')) inline in every
    handler. When no Shopify Access record exists, get_value returns None
    and get_doc('Shopify Access', None) throws 'Shopify Access None not
    found', which breaks unrelated operations (e.g. creating an Item).
    This helper returns None instead, and callers skip the sync.
    """
    name = frappe.get_value('Shopify Access', {}, 'name')
    if not name:
        return None
    return frappe.get_doc('Shopify Access', name)
PYEOF
echo "  utils.py written"

echo "== Patching handlers to use get_shopify_access() and guard None =="

# create_product.py: Item.after_insert
python3 - "$APP_DIR/create_product.py" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    'import requests\nimport frappe\nimport json\nfrom requests.auth import HTTPBasicAuth',
    'import requests\nimport frappe\nimport json\nfrom requests.auth import HTTPBasicAuth\nfrom shopify.utils import get_shopify_access'
)
s = s.replace(
    '''    # Fetch Shopify Access credentials
    shopify_doc = frappe.get_doc(
        "Shopify Access",
        frappe.get_value("Shopify Access", {}, "name")  # first Shopify Access record
    )

    shopify_url = shopify_doc.shopify_url''',
    '''    # Fetch Shopify Access credentials
    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return

    shopify_url = shopify_doc.shopify_url'''
)
open(p, 'w').write(s)
print("  patched create_product.py")
PYEOF

# update_product.py: Item.on_update
python3 - "$APP_DIR/update_product.py" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    'import requests\nimport frappe\nimport json\nfrom requests.auth import HTTPBasicAuth',
    'import requests\nimport frappe\nimport json\nfrom requests.auth import HTTPBasicAuth\nfrom shopify.utils import get_shopify_access'
)
s = s.replace(
    '''    shopify_doc = frappe.get_doc(
        "Shopify Access",
        frappe.get_value("Shopify Access", {}, "name")  # first Shopify Access record
    )
    
    # Determine Shopify status''',
    '''    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    
    # Determine Shopify status'''
)
open(p, 'w').write(s)
print("  patched update_product.py")
PYEOF

# delete_product.py: Item.on_trash
python3 - "$APP_DIR/delete_product.py" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    'import requests\nimport frappe\nimport json\nfrom requests.auth import HTTPBasicAuth',
    'import requests\nimport frappe\nimport json\nfrom requests.auth import HTTPBasicAuth\nfrom shopify.utils import get_shopify_access'
)
s = s.replace(
    '''    shopify_doc = frappe.get_doc(
        "Shopify Access",
        frappe.get_value("Shopify Access", {}, "name")  # first Shopify Access record
    )

    shopify_url = shopify_doc.shopify_url''',
    '''    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return

    shopify_url = shopify_doc.shopify_url'''
)
open(p, 'w').write(s)
print("  patched delete_product.py")
PYEOF

# create_order.py: Sales Order.on_save
python3 - "$APP_DIR/create_order.py" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    'import requests\nimport frappe\nimport json',
    'import requests\nimport frappe\nimport json\nfrom shopify.utils import get_shopify_access'
)
s = s.replace(
    '''    shopify_doc = frappe.get_doc(
        "Shopify Access",
        frappe.get_value("Shopify Access", {}, "name")  # first Shopify Access record
    )
    
    shopify_order_id= create_shopify_order''',
    '''    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    
    shopify_order_id= create_shopify_order'''
)
open(p, 'w').write(s)
print("  patched create_order.py")
PYEOF

# update_order.py: Sales Order.on_update
python3 - "$APP_DIR/update_order.py" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    'import requests\nimport frappe\nimport json',
    'import requests\nimport frappe\nimport json\nfrom shopify.utils import get_shopify_access'
)
s = s.replace(
    '''    shopify_doc = frappe.get_doc(
        "Shopify Access",
        frappe.get_value("Shopify Access", {}, "name")  # first Shopify Access record
    )
    update_shopify_order''',
    '''    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    update_shopify_order'''
)
open(p, 'w').write(s)
print("  patched update_order.py")
PYEOF

# cancel_order.py: Sales Order.on_cancel
python3 - "$APP_DIR/cancel_order.py" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    'import requests\nimport frappe\nimport json',
    'import requests\nimport frappe\nimport json\nfrom shopify.utils import get_shopify_access'
)
s = s.replace(
    '''    shopify_doc = frappe.get_doc(
        "Shopify Access",
        frappe.get_value("Shopify Access", {}, "name")
    )
    cancel_shopify_order''',
    '''    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    cancel_shopify_order'''
)
open(p, 'w').write(s)
print("  patched cancel_order.py")
PYEOF

# delete_order.py: Sales Order.on_trash
python3 - "$APP_DIR/delete_order.py" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    'import requests\nimport frappe\nimport json',
    'import requests\nimport frappe\nimport json\nfrom shopify.utils import get_shopify_access'
)
s = s.replace(
    '''    shopify_doc = frappe.get_doc("Shopify Access", frappe.get_value("Shopify Access", {}, "name"))
    delete_shopify_order''',
    '''    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    delete_shopify_order'''
)
open(p, 'w').write(s)
print("  patched delete_order.py")
PYEOF

# create_customer.py: Customer.after_insert
python3 - "$APP_DIR/create_customer.py" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    'import requests\nimport frappe\nimport json',
    'import requests\nimport frappe\nimport json\nfrom shopify.utils import get_shopify_access'
)
s = s.replace(
    '''    shopify_doc = frappe.get_doc(
        "Shopify Access",
        frappe.get_value("Shopify Access", {}, "name")
    )
    customer = create_shopify_customer''',
    '''    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    customer = create_shopify_customer'''
)
open(p, 'w').write(s)
print("  patched create_customer.py")
PYEOF

# update_customer.py: Customer.on_update
python3 - "$APP_DIR/update_customer.py" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    'import requests\nimport frappe\nimport json',
    'import requests\nimport frappe\nimport json\nfrom shopify.utils import get_shopify_access'
)
s = s.replace(
    '''    shopify_doc = frappe.get_doc("Shopify Access", frappe.get_value("Shopify Access", {}, "name"))

    update_shopify_customer_by_email''',
    '''    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return

    update_shopify_customer_by_email'''
)
open(p, 'w').write(s)
print("  patched update_customer.py")
PYEOF

# delete_customer.py: Customer.on_trash
python3 - "$APP_DIR/delete_customer.py" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    'import requests\nimport frappe\nimport json',
    'import requests\nimport frappe\nimport json\nfrom shopify.utils import get_shopify_access'
)
s = s.replace(
    '''    shopify_doc = frappe.get_doc("Shopify Access", frappe.get_value("Shopify Access", {}, "name"))
    delete_shopify_customer''',
    '''    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    delete_shopify_customer'''
)
open(p, 'w').write(s)
print("  patched delete_customer.py")
PYEOF

# update_product_inventory.py: Item.on_submit (inventory)
python3 - "$APP_DIR/update_product_inventory.py" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    'import requests\nimport frappe\nimport json',
    'import requests\nimport frappe\nimport json\nfrom shopify.utils import get_shopify_access'
)
s = s.replace(
    '''    shopify_doc = frappe.get_doc(
        "Shopify Access",
        frappe.get_value("Shopify Access", {}, "name")  # first Shopify Access record
    )
    update_shopify_product''',
    '''    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    update_shopify_product'''
)
open(p, 'w').write(s)
print("  patched update_product_inventory.py")
PYEOF

echo "== Restarting bench serve =="
pkill -f 'frappe serve' 2>/dev/null
pkill -f 'bench serve' 2>/dev/null
sleep 3
( cd "$BENCH_DIR" && setsid nohup bench serve --port 8000 > /tmp/bench-serve.log 2>&1 < /dev/null & disown )

echo "== Waiting for site =="
for i in $(seq 1 40); do
  if curl -s -o /dev/null -H "Host: frontend" "http://localhost:8000/api/method/ping"; then
    echo "  site responding"
    break
  fi
  sleep 3
done

echo "== Verification: import helper + simulate Item creation =="
cd "$BENCH_DIR" || exit 1
bench --site frontend console <<'PYEOF'
import frappe
from shopify.utils import get_shopify_access
print("get_shopify_access() ->", get_shopify_access())
# Simulate the create_product.after_insert path with no Shopify Access configured
from shopify import create_product
class Dummy:
    shopify_product_id = None
    disabled = False
    show_in_website = True
    item_code = "TEST-ITEM"
    item_name = "Test Item"
    description = "test"
    standard_rate = 10
    weight_per_unit = 1
    opening_stock = 5
    image = None
d = Dummy()
create_product.after_insert(d, None)
print("after_insert completed without error (no Shopify Access configured)")
PYEOF

echo "== Done =="
