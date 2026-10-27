#!/usr/bin/env bash
# Functional test of the shopify "Shopify Access None" guard on THIS site.
# The plain REST Item-create test fails here for an unrelated pre-existing
# sandbox reason (no Item Group / UOM master data), so instead we invoke the
# guarded doc_event handlers directly with a minimal stand-in doc. With no
# Shopify Access record configured, every guarded handler must return without
# raising "Shopify Access None not found".
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

cat > apps/shopify/shopify/_diag_guard.py <<'PYEOF'
import frappe
from types import SimpleNamespace

def run():
    print("Shopify Access records:", frappe.db.count("Shopify Access"))
    print("get_shopify_access() ->", frappe.get_doc("Shopify Access") if False else __import__("shopify.utils", fromlist=["get_shopify_access"]).get_shopify_access())

    # Minimal doc stand-ins; guarded handlers should early-return on None.
    item = SimpleNamespace(name="TEST-GUARD-ITEM", item_code="TEST-GUARD-ITEM",
                           shopify_product_id=None, flags=SimpleNamespace())
    so = SimpleNamespace(name="TEST-GUARD-SO", shopify_order_id=None, amended_from=None,
                         status="Draft", flags=SimpleNamespace())
    cust = SimpleNamespace(name="TEST-GUARD-CUST", shopify_customer_id=None,
                           flags=SimpleNamespace())

    import shopify.create_product as cp
    import shopify.update_product as up
    import shopify.delete_product as dp
    import shopify.create_order as co
    import shopify.update_order as uo
    import shopify.cancel_order as ca
    import shopify.delete_order as do
    import shopify.create_customer as cc
    import shopify.update_customer as uc
    import shopify.delete_customer as dc

    cases = [
        ("Item.after_insert        -> create_product.after_insert", cp.after_insert, item),
        ("Item.on_update          -> update_product.on_submit",      up.on_submit, item),
        ("Item.on_trash           -> delete_product.on_submit",      dp.on_submit, item),
        ("SalesOrder.on_save      -> create_order.on_submit",        co.on_submit, so),
        ("SalesOrder.on_update    -> update_order.on_submit",        uo.on_submit, so),
        ("SalesOrder.on_cancel    -> cancel_order.on_submit",        ca.on_submit, so),
        ("SalesOrder.on_trash     -> delete_order.on_submit",        do.on_submit, so),
        ("Customer.after_insert   -> create_customer.on_submit",     cc.on_submit, cust),
        ("Customer.on_update      -> update_customer.on_submit",     uc.on_submit, cust),
        ("Customer.on_trash       -> delete_customer.on_submit",     dc.on_submit, cust),
    ]
    for label, fn, doc in cases:
        try:
            fn(doc, None)
            print("OK   " + label + " (returned cleanly)")
        except Exception as e:
            print("FAIL %s -> %s: %s" % (label, type(e).__name__, e))
PYEOF

bench --site frontend execute shopify._diag_guard.run
rm -f apps/shopify/shopify/_diag_guard.py
