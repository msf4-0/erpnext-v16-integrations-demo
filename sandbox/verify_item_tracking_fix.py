# -*- coding: utf-8 -*-
"""Verify the item_tracking QR + lookup fix against the live site."""
import frappe

frappe.init(site="frontend", sites_path="/home/frappe/frappe-bench/sites")
frappe.connect()

from item_tracking.item_tracking.doctype.tracked_item.tracked_item import (
    _tracked_item_qr_url,
    get_tracking_qr_image,
    get_tracking_barcode_image,
)
from item_tracking.item_tracking.api import lookup_tracked_item

# 1. Ensure at least one Tracked Item exists.
existing = frappe.db.get_value("Tracked Item", {}, "name")
if not existing:
    from item_tracking.item_tracking.doctype.tracked_item.tracked_item import bulk_create_tracked_items
    item = frappe.db.get_value("Item", {"is_stock_item": 1, "disabled": 0}, "name", order_by="name")
    existing = bulk_create_tracked_items(item, 1)[0]

print("tracked_id:", existing)
print("qr_payload:", repr(_tracked_item_qr_url(existing)))
qr = get_tracking_qr_image(existing)
print("qr_image:", qr)
assert not qr.startswith("http"), "QR payload must be a raw id, got URL-ish image path %r" % qr

bc = get_tracking_barcode_image(existing)
print("barcode_image:", bc)

info = lookup_tracked_item(existing)
print("lookup:", info)
assert info.get("tracking_id") == existing

# Confirm the payload is the bare id (no /tracked_item_lookup URL anywhere).
assert _tracked_item_qr_url(existing) == existing, "payload should equal raw tracking_id"
print("=== ITEM TRACKING FIX VERIFIED ===")

frappe.destroy()
