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