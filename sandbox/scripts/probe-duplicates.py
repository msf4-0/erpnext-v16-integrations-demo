#!/usr/bin/env python3
"""Look for duplicate Shopify-imported documents (orders / customers / items).

The Shopify sync runs on a Frappe scheduler tick (hooks.py `scheduler_events.all`),
so any gap in its de-duplication shows up as a multiplying set of Sales Orders.
"""
import os
from collections import Counter

import frappe

SITE = os.environ.get("SITE_NAME", "frontend")
os.chdir("/home/frappe/frappe-bench/sites")
frappe.init(site=SITE, sites_path=".")
frappe.connect()
frappe.set_user("Administrator")

orders = frappe.get_all(
    "Sales Order", fields=["name", "shopify_order_id", "creation"], order_by="creation asc"
)
print("PROBE sales_orders=%d" % len(orders))
ids = Counter(str(o.shopify_order_id or "") for o in orders)
empty = ids.pop("", 0)
print("PROBE empty_shopify_id=%d distinct_ids=%d" % (empty, len(ids)))
dupes = {k: v for k, v in ids.items() if v > 1}
print("PROBE duplicate_ids=%d total_dupe_rows=%d" % (len(dupes), sum(v - 1 for v in dupes.values())))
for oid, n in list(dupes.items())[:5]:
    names = [o.name for o in orders if str(o.shopify_order_id or "") == oid]
    print("PROBE  order %s x%d -> %s" % (oid, n, ", ".join(names[:6])))

customers = frappe.get_all("Customer", fields=["name", "shopify_customer_id", "customer_name"])
cids = Counter(str(c.shopify_customer_id or "") for c in customers)
print("PROBE customers=%d empty_shopify_id=%d distinct_ids=%d" % (len(customers), cids.get("", 0), len(cids) - (1 if "" in cids else 0)))
names = Counter(c.customer_name for c in customers)
dupe_names = {k: v for k, v in names.items() if v > 1}
print("PROBE duplicate_customer_names=%d total_extra=%d" % (len(dupe_names), sum(v - 1 for v in dupe_names.values())))
for nm, n in list(dupe_names.items())[:5]:
    rows = [c.name for c in customers if c.customer_name == nm]
    print("PROBE  customer %r x%d -> %s" % (nm, n, ", ".join(rows[:5])))

items = frappe.get_all("Item", fields=["name", "shopify_product_id"])
print("PROBE items=%d with_shopify_id=%d" % (len(items), sum(1 for i in items if i.shopify_product_id)))
frappe.destroy()
