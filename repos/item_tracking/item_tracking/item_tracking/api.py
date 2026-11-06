# -*- coding: utf-8 -*-
"""Scan resolution + lookup. The scan popup calls `lookup_tracked_item`."""
from __future__ import unicode_literals

import frappe
from frappe.utils import cstr, flt
from urllib.parse import unquote


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

    # QR encodes a URL: item_qr?item_code=..&barcode=.. (SKU label) or
    # tracked_item_lookup?tracking_id=.. (unit label). Extract the value.
    if "?" in value and "=" in value:
        qs = value.split("?", 1)[-1]
        params = {}
        for part in qs.split("&"):
            k, _, v = part.partition("=")
            if k:
                params[k] = unquote(v)
        for key in ("tracking_id", "item_code", "barcode", "serial_no", "batch_no"):
            if params.get(key):
                value = params[key]
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
        return _lookup_item(value)

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


def _lookup_item(value):
    """Resolve a SKU barcode / item code / serial / batch to an Item summary
    (used when the scanned value is not a per-unit tracked item)."""
    value = cstr(value).strip()
    item_code = None

    # A 1D barcode label sometimes carries the Barcode Printing document name
    # (e.g. "BP-2026-11-05-00008") instead of a product code. Resolve it to the
    # item it holds so the popup shows a product name, not a raw document id.
    if frappe.db.exists("Barcode Printing", value):
        item_code = frappe.db.get_value("Barcode Generator Items", {"parent": value}, "item_code")

    barcode_row = frappe.db.get_value("Item Barcode", {"barcode": value}, "parent")
    if barcode_row:
        item_code = barcode_row
    elif frappe.db.exists("Item", value):
        item_code = value
    else:
        serial = frappe.db.get_value("Serial No", value, "item_code")
        if serial:
            item_code = serial
        else:
            batch = frappe.db.get_value("Batch", value, "item")
            if batch:
                item_code = batch

    if not item_code or not frappe.db.exists("Item", item_code):
        return {}

    item_name = frappe.db.get_value("Item", item_code, "item_name")
    stock_qty = frappe.db.sql(
        "SELECT COALESCE(SUM(actual_qty), 0) FROM `tabBin` WHERE item_code = %s", item_code
    )[0][0] or 0
    tracked_count = frappe.db.count("Tracked Item", {"item_code": item_code})

    return {
        "item_code": item_code,
        "item_name": item_name,
        "stock_qty": flt(stock_qty),
        "tracked_count": tracked_count,
        "is_item": True,
    }


@frappe.whitelist()
def add_tracked_item_to_stock_entry(tracking_id):
    """Resolve a scan into the payload the Stock Entry client script needs.

    Returns {tracking_id, item_code, item_name, current_warehouse} or {} so the
    client can add both the item row and the `tracked_items` child row, and
    reject duplicates (spec §5 step 6, §10 Test 8).
    """
    return lookup_tracked_item(tracking_id)
