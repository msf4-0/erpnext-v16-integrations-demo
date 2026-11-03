# -*- coding: utf-8 -*-
"""Scan resolution + lookup. The scan popup calls `lookup_tracked_item`."""
from __future__ import unicode_literals

import frappe
from frappe.utils import cstr


@frappe.whitelist()
def lookup_tracked_item(search_value):
    """Resolve one scanned QR/barcode/manual id to a unit + its live info.

    Returns exactly the fields the popup needs (spec §2): product name, unique
    id, current location, plus a flag when the unit is out of a warehouse.
    Accepts: raw tracking_id, a `tracked_item_lookup?tracking_id=...` QR URL,
    or a Tracked Item's barcode (which equals its tracking_id).
    """
    value = cstr(search_value or "").strip()
    if not value:
        return {}

    # QR encodes a URL — pull the tracking_id out of the query string.
    if "tracking_id=" in value:
        qs = value.split("?", 1)[-1]
        params = frappe.parse_json("{}")  # noqa
        for part in qs.split("&"):
            k, _, v = part.partition("=")
            if k == "tracking_id":
                value = v
                break

    tracked = frappe.db.get_value(
        "Tracked Item", {"name": value},
        ["name", "serial_no", "item_code", "item_name", "current_warehouse",
         "current_status", "last_transaction", "last_movement_date"],
        as_dict=True,
    )
    if not tracked:
        tracked = frappe.db.get_value(
            "Tracked Item", {"barcode": value},
            ["name", "serial_no", "item_code", "item_name", "current_warehouse",
             "current_status", "last_transaction", "last_movement_date"],
            as_dict=True,
        )
    if not tracked:
        return {}

    history = frappe.get_all(
        "Item Tracking History",
        filters={"parent": tracked.name},
        fields=["transaction_type", "transaction_reference", "previous_warehouse",
                "new_warehouse", "movement_date", "performed_by"],
        order_by="idx asc",
    )

    return {
        "tracking_id": tracked.name,
        "serial_no": tracked.serial_no,
        "item_code": tracked.item_code,
        "item_name": tracked.item_name,
        "current_warehouse": tracked.current_warehouse,
        "current_status": tracked.current_status,
        "last_transaction": tracked.last_transaction,
        "last_movement_date": tracked.last_movement_date,
        "in_transit": tracked.current_warehouse is None
        and tracked.current_status in ("Dispatched", "Delivered", "In Transit"),
        "status_history": history,
    }


@frappe.whitelist()
def add_tracked_item_to_stock_entry(tracking_id):
    """Resolve a scan into the payload the Stock Entry client script needs.

    Returns {tracking_id, item_code, item_name, current_warehouse} or {} so the
    client can add both the item row and the `tracked_items` child row, and
    reject duplicates (spec §5 step 6, §10 Test 8).
    """
    return lookup_tracked_item(tracking_id)
