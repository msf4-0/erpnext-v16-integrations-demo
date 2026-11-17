"""Runs INSIDE the bench container (via runpy) to replay one recorded order.

Reads /tmp/shopify-order.json and calls the real mapping code with a warehouse,
which the live sync leaves unset (stock items then fail WarehouseRequired).
"""

import json

import frappe

from shopify.retrieve_order import create_sales_order

with open("/tmp/shopify-order.json", encoding="utf-8") as fh:
    order = json.load(fh)

warehouse = frappe.db.get_value(
    "Warehouse", {"is_group": 0, "disabled": 0}, "name"
)
print("replay: shopify order {0} ({1})".format(order.get("id"), order.get("name")))
print("replay: warehouse = {0}".format(warehouse))

before = frappe.db.get_value(
    "Sales Order", {"shopify_order_id": str(order.get("id"))}, "name"
)
create_sales_order(order, warehouse=warehouse)
after = frappe.db.get_value(
    "Sales Order", {"shopify_order_id": str(order.get("id"))}, "name"
)
print("replay: sales order before = {0}".format(before))
print("replay: sales order after  = {0}".format(after))
print("replay: OK" if after else "replay: FAILED (no Sales Order)")
