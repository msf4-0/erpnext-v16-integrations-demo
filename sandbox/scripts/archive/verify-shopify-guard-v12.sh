#!/usr/bin/env bash
# CANONICAL guard verification for the shopify LOCAL FORK on v12.
#
# Proves the fork's headline fix: every shopify doc_event handler must
# early-return instead of raising "Shopify Access None not found" when no
# store is configured. Upstream did
#   frappe.get_doc("Shopify Access", frappe.get_value("Shopify Access", {}, "name"))
# which throws when get_value returns None; the fork adds
# shopify.utils.get_shopify_access() and guards the handlers.
#
# Two independent angles:
#  1. Direct: invoke the guarded handlers with stand-in docs and assert none
#     raises "Shopify Access None not found".
#  2. End-to-end: seed the minimal Item master data (UOM + Item Group) the v12
#     baseline lacks, then create a real Item over authenticated REST so
#     Item.after_insert -> create_product.after_insert actually fires.
#
# (Supersedes the earlier verify-shopify-guard2-v12.sh / guard3-v12.sh
# iterations, which are kept only as stubs.)
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

echo "== direct guard test =="
cat > apps/shopify/shopify/_diag_guard.py <<'PYEOF'
import frappe

def run():
    from shopify.utils import get_shopify_access
    import shopify.create_product as cp
    import shopify.create_customer as cc
    import shopify.create_order as co

    print("Shopify Access records:", frappe.db.count("Shopify Access"))
    print("get_shopify_access() ->", get_shopify_access())

    class D(dict):
        def __getattr__(self, k):
            return self.get(k)

    item = D(item_code="GUARD-I", item_name="Guard I", name="GUARD-I",
             shopify_product_id=None, disabled=0, show_in_website=0)
    cust = D(name="GUARD-C", customer_name="Guard C", shopify_customer_id=None)
    order = D(name="GUARD-O", shopify_order_id=None, customer="GUARD-C",
              customer_name="Guard C", items=[], delivery_date=None)

    checks = [("create_product.after_insert", lambda: cp.after_insert(item, None)),
              ("create_customer.on_submit", lambda: cc.on_submit(cust, None)),
              ("create_order.on_submit", lambda: co.on_submit(order, None))]
    for label, fn in checks:
        try:
            r = fn()
            print("OK   %s -> %r (early-returned, no 'None not found')" % (label, r))
        except Exception as e:
            verdict = "FAIL" if "None not found" in str(e) else "WARN"
            print("%s %s -> %s: %s" % (verdict, label, type(e).__name__, e))
PYEOF
bench --site frontend execute shopify._diag_guard.run
rm -f apps/shopify/shopify/_diag_guard.py

echo "== seed minimal Item master data (UOM + Item Group) =="
cat > apps/shopify/shopify/_diag_seed.py <<'PYEOF'
import frappe

def run():
    for dt, name, field in (("UOM", "Nos", "uom_name"),
                            ("Item Group", "All Item Groups", "item_group_name")):
        if frappe.db.exists(dt, name):
            print("exists", dt, name)
            continue
        d = frappe.new_doc(dt)
        d.__setattr__(field, name)
        if dt == "Item Group":
            d.is_group = 0
        d.insert(ignore_permissions=True)
        print("created", dt, name)
    frappe.db.commit()
PYEOF
bench --site frontend execute shopify._diag_seed.run
rm -f apps/shopify/shopify/_diag_seed.py

echo "== authenticated REST: real Item create (fires Item.after_insert) =="
curl -s -c /tmp/c.txt -H "Host: frontend" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' http://localhost:8000/api/method/login > /dev/null
ITEM_CODE="GUARD-TEST-V12-$(date +%s)"
RESP=$(curl -s -b /tmp/c.txt -H "Host: frontend" -H "Content-Type: application/json" \
  -w '\nHTTP_CODE:%{http_code}' \
  -d "{\"item_code\":\"$ITEM_CODE\",\"item_name\":\"Guard Test Item\",\"item_group\":\"All Item Groups\",\"stock_uom\":\"Nos\",\"is_stock_item\":0}" \
  "http://localhost:8000/api/resource/Item")
echo "$RESP"
if echo "$RESP" | grep -q "Shopify Access None not found"; then
  echo "FAIL: 'Shopify Access None not found' raised on real Item create"
elif echo "$RESP" | grep -qE 'HTTP_CODE:(200|201)'; then
  echo "OK: Item created and the after_insert hook did NOT raise the bug"
else
  echo "NOTE: Item create did not succeed — see response (master data may be incomplete)"
fi
curl -s -b /tmp/c.txt -H "Host: frontend" -X DELETE \
  "http://localhost:8000/api/resource/Item/$ITEM_CODE" -o /dev/null -w "cleanup delete HTTP %{http_code}\n"
