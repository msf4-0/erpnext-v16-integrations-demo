# -*- coding: utf-8 -*-
from __future__ import unicode_literals

import frappe
from frappe.model.document import Document
from frappe.utils import cstr, get_url


class TrackedItem(Document):
    """One physical unit. Identity is `tracking_id`; barcode and QR both encode it."""

    def before_insert(self):
        # Runs BEFORE frappe sets the name from autoname "field:tracking_id".
        if not self.tracking_id:
            self.tracking_id = _next_tracking_id(self.item_code)
        if frappe.db.exists("Tracked Item", self.tracking_id):
            frappe.throw("Tracking ID {0} already exists".format(self.tracking_id))
        self.barcode = cstr(self.tracking_id)

    def validate(self):
        self.item_name = frappe.db.get_value("Item", self.item_code, "item_name")
        if not self.tracking_id:
            self.tracking_id = _next_tracking_id(self.item_code)
        if not self.serial_no:
            self.serial_no = _next_serial_no()
        self.barcode = cstr(self.tracking_id)
        self.qr_code = _tracked_item_qr_url(self.tracking_id)


def _next_tracking_id(item_code):
    base = "%s-" % cstr(item_code).strip()
    idx = 1
    while True:
        candidate = "%s%04d" % (base, idx)
        if not frappe.db.exists("Tracked Item", candidate):
            return candidate
        idx += 1


def _next_serial_no():
    """Next globally-unique physical serial number (SN-00000001, SN-00000002, ...).

    Assigned on save whenever empty — which is how an item receives its serial on
    a status transition (submit/cancel re-save the Tracked Item).
    """
    row = frappe.db.sql(
        "SELECT serial_no FROM `tabTracked Item` "
        "WHERE serial_no IS NOT NULL AND serial_no != '' "
        "ORDER BY serial_no DESC LIMIT 1"
    )
    last = 0
    if row and row[0][0]:
        try:
            last = int(cstr(row[0][0]).replace("SN-", ""))
        except (ValueError, TypeError):
            last = 0
    return "SN-%08d" % (last + 1)


def _tracked_item_qr_url(tracking_id):
    """Return the raw tracking_id as the QR payload.

    The QR encodes the unique ID itself (the primary identifier), not a URL to a
    web page, so scanning it inside the ERPNext Desk resolves the unit inline via
    `lookup_tracked_item` and shows the popup — no detached /tracked_item_lookup page.
    """
    return cstr(tracking_id)


@frappe.whitelist()
def bulk_create_tracked_items(item_code, qty, warehouse=None, status="In Stock"):
    item_code = cstr(item_code).strip()
    qty = int(qty)
    if qty < 1:
        frappe.throw("Quantity must be at least 1")
    if not frappe.db.exists("Item", item_code):
        frappe.throw("Item {0} does not exist".format(item_code))
    created = []
    for _ in range(qty):
        doc = frappe.new_doc("Tracked Item")
        doc.item_code = item_code
        doc.current_warehouse = warehouse
        doc.current_status = status
        doc.insert(ignore_permissions=True)
        created.append(doc.name)
    return created


@frappe.whitelist()
def bulk_transfer_tracked_items(rows):
    """Mass-create Tracked Items (one barcode/QR per physical unit) for MANY
    items in a single call.

    `rows` is a JSON list of ``{"item_code": ..., "qty": N, "warehouse": ...}``.
    Unlike the per-item helper above, this resolves every item in one query and
    pre-seeds the tracking-id / serial-number sequences locally so it does NOT
    re-scan the whole table on each row — it stays fast for hundreds of units.
    """
    if isinstance(rows, str):
        rows = frappe.parse_json(rows)
    if not rows:
        frappe.throw("No items to transfer")

    rows = [r for r in rows if r and cstr(r.get("item_code") or "").strip()]
    if not rows:
        frappe.throw("No item codes provided")

    item_codes = list({cstr(r.get("item_code")).strip() for r in rows})

    # Resolve every item name in ONE query (no per-row lookup).
    items = frappe.db.get_all(
        "Item",
        filters={"name": ["in", item_codes]},
        fields=["name", "item_name"],
    )
    name_map = {i.get("name"): i.get("item_name") for i in items}
    missing = [c for c in item_codes if c not in name_map]
    if missing:
        frappe.throw("Items do not exist: {0}".format(", ".join(missing)))

    # Seed the global serial sequence once, then increment locally.
    serial_cur = int(cstr(_next_serial_no()).replace("SN-", "") or 0)

    created = []
    for r in rows:
        code = cstr(r.get("item_code")).strip()
        qty = int(r.get("qty") or 1)
        warehouse = r.get("warehouse") or None
        status = r.get("status") or "In Stock"

        # Next tracking-id index for THIS item, from one MAX query.
        base = "%s-" % code
        last = frappe.db.sql(
            "SELECT name FROM `tabTracked Item` "
            "WHERE name LIKE %s ORDER BY name DESC LIMIT 1",
            (base + "%",),
        )
        idx = 1
        if last and last[0][0]:
            try:
                idx = int(cstr(last[0][0])[len(base):]) + 1
            except (ValueError, TypeError):
                idx = 1

        for _ in range(qty):
            tracking_id = "%s%04d" % (base, idx)
            serial_no = "SN-%08d" % serial_cur
            idx += 1
            serial_cur += 1

            doc = frappe.new_doc("Tracked Item")
            doc.tracking_id = tracking_id
            doc.serial_no = serial_no
            doc.item_code = code
            doc.item_name = name_map.get(code)
            doc.current_warehouse = warehouse
            doc.current_status = status
            # tracking_id/serial_no are pre-set, so before_insert/validate skip
            # the expensive _next_tracking_id / _next_serial_no table scans.
            doc.insert(ignore_permissions=True)
            created.append(tracking_id)

    return {"created": len(created), "tracking_ids": created}


@frappe.whitelist()
def get_tracking_barcode_image(tracking_id, barcode_type="CODE128", width=None, height=None):
    try:
        from barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing import (
            get_barcode_image,
        )
        return get_barcode_image(tracking_id, barcode_type, width, height, display_value=1)
    except Exception:
        from item_tracking.item_tracking.doctype.tracked_item.raster import render_barcode
        return render_barcode(tracking_id, barcode_type)


@frappe.whitelist()
def get_tracking_qr_image(tracking_id):
    """Render a QR PNG that encodes the raw tracking_id (the primary identifier).

    Uses the app-local raster renderer so the payload is the bare ID, never a URL
    to a web page — an in-Desk scan resolves it inline through lookup_tracked_item.
    """
    from item_tracking.item_tracking.doctype.tracked_item.raster import render_qr
    return render_qr(cstr(tracking_id))