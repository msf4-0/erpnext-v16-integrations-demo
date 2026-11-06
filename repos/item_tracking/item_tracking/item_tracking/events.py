# -*- coding: utf-8 -*-
"""Stock transaction lifecycle hooks.

Locations and history change ONLY here, on submit/cancel of a real transaction
— never on scan (spec §5). Existing ERPNext stock validation/accounting runs
first; these hooks read the child table the scan UI populates.
"""
from __future__ import unicode_literals

import frappe
from frappe import _
from frappe.utils import now, cstr


def _tracked_rows(doc):
    return doc.get("tracked_items") or []


def _resolve_new_warehouse(doc, item_code):
    """The unit's destination warehouse for this Stock Entry, or None for
    outbound-only purposes (Material Issue / issue arm of Manufacture)."""
    for d in doc.items:
        if d.item_code == item_code:
            if d.t_warehouse:
                return d.t_warehouse
            # outbound row: leaving stock entirely
            return None
    return None


def _status_for(new_warehouse, stock_entry_type):
    if new_warehouse:
        return "In Stock"
    return "Consumed"


def validate_stock_entry_tracked_items(doc, method):
    """Spec Test 5 (invalid movement) + Test 8 (duplicate scan), server-side."""
    seen = set()
    for row in _tracked_rows(doc):
        tid = row.tracked_item
        if tid in seen:
            frappe.throw(_("Tracked item {0} was scanned twice in this Stock Entry").format(tid))
        seen.add(tid)

        tracked = frappe.get_doc("Tracked Item", tid)
        # Find this unit's source warehouse among the SE rows.
        source = None
        for d in doc.items:
            if d.item_code == tracked.item_code and d.s_warehouse:
                source = d.s_warehouse
                break
        if source and tracked.current_warehouse and tracked.current_warehouse != source:
            frappe.throw(
                _("Tracked item {0} ({1}) is currently in {2}, not {3}. "
                  "Cannot move it from a warehouse it is not in.").format(
                    tid, tracked.item_code, tracked.current_warehouse, source
                )
            )


def _auto_create_tracked_items(item_code, qty, warehouse):
    """Create one Tracked Item (QR + barcode) per physical unit received, so
    every item has its label from the moment it enters stock — no manual
    "Create Tracked Units" step."""
    try:
        from item_tracking.item_tracking.doctype.tracked_item.tracked_item import bulk_create_tracked_items
        qty = int(qty or 0)
        if qty > 0 and item_code:
            return bulk_create_tracked_items(item_code, qty, warehouse)
    except Exception:
        frappe.log_error(title="item_tracking auto-create failed", message=frappe.get_traceback())
    return []


def _create_finished_good_barcode_printing(doc):
    """Assemble a ready-to-print Barcode Printing document for the finished goods
    of a Manufacture Stock Entry and surface a bottom-right notification linking
    to it.

    Each finished unit already has a Tracked Item (unique serial_no + barcode +
    QR) created by `_auto_create_tracked_items` above; this only assembles the
    print document (one row per finished good, serial numbers pre-filled) so the
    operator opens the link and the barcodes/QRs are already generated.
    """
    finished = [d for d in doc.items if d.t_warehouse and (d.qty or 0) > 0]
    if not finished:
        return None

    try:
        from barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing import (
            se_make_barcode,
        )
        bp = se_make_barcode(doc.name)  # unsaved Barcode Printing (finished-goods rows only)
    except Exception:
        frappe.log_error(title="manufacture barcode: se_make_barcode failed", message=frappe.get_traceback())
        return None

    # Pre-fill each row's serial_no with the serial numbers minted for this
    # finished good, so the "serial" barcode preview is ready to print.
    for row in bp.get("items") or []:
        if not row.item_code:
            continue
        limit = int(row.qty or 0)
        tracked = frappe.get_all(
            "Tracked Item",
            filters={"item_code": row.item_code},
            fields=["serial_no"],
            order_by="creation desc",
            limit=limit or None,
        )
        serials = [t.serial_no for t in tracked if t.serial_no]
        if serials:
            row.serial_no = "\n".join(serials)

    try:
        bp.insert(ignore_permissions=True)
    except Exception:
        frappe.log_error(title="manufacture barcode: insert failed", message=frappe.get_traceback())
        return None

    link = "/desk/barcode-printing/{0}".format(bp.name)
    frappe.msgprint(
        _("Finished goods complete. Serial numbers and QR codes are ready — "
          "<a href='{0}'>Open Barcode Printing</a>.").format(link),
        title=_("Finished Good"),
        indicator="green",
        alert=True,
    )
    return bp


def on_purchase_receipt_submit(doc, method):
    """Auto-create Tracked Items for every unit received on a Purchase Receipt."""
    for item in doc.items:
        if (item.qty or 0) > 0:
            _auto_create_tracked_items(item.item_code, item.qty, item.warehouse or doc.set_warehouse)


def on_stock_entry_submit(doc, method):
    # Auto-create tracked units for inbound receipts (Material Receipt /
    # Manufacture output) so no manual tracking step is needed.
    if doc.stock_entry_type in ("Material Receipt", "Manufacture"):
        for item in doc.items:
            if item.t_warehouse and (item.qty or 0) > 0:
                _auto_create_tracked_items(item.item_code, item.qty, item.t_warehouse)

    # Manufacture: finished goods get serial numbers + barcodes + QR, and a
    # ready-made Barcode Printing document linked from a bottom-right notification.
    if doc.stock_entry_type == "Manufacture":
        _create_finished_good_barcode_printing(doc)

    for row in _tracked_rows(doc):
        tid = row.tracked_item
        if not tid or not frappe.db.exists("Tracked Item", tid):
            continue
        tracked = frappe.get_doc("Tracked Item", tid)
        prev_wh = tracked.current_warehouse
        new_wh = _resolve_new_warehouse(doc, tracked.item_code)

        tracked.append("item_tracking_history", {
            "transaction_type": "Stock Entry",
            "transaction_reference": doc.name,
            "previous_warehouse": prev_wh,
            "new_warehouse": new_wh,
            "movement_date": now(),
            "performed_by": frappe.session.user,
        })
        tracked.current_warehouse = new_wh
        tracked.current_status = _status_for(new_wh, doc.stock_entry_type)
        tracked.last_transaction = doc.name
        tracked.last_movement_date = now()
        tracked.save(ignore_permissions=True)


def on_stock_entry_cancel(doc, method):
    """Reverse the submit: restore previous_warehouse, drop the history row."""
    for row in _tracked_rows(doc):
        tid = row.tracked_item
        if not tid or not frappe.db.exists("Tracked Item", tid):
            continue
        tracked = frappe.get_doc("Tracked Item", tid)
        history = tracked.get("item_tracking_history") or []
        # Find the newest history entry written by THIS Stock Entry and undo it.
        for i in range(len(history) - 1, -1, -1):
            h = history[i]
            if h.transaction_reference == doc.name:
                tracked.current_warehouse = h.previous_warehouse
                tracked.current_status = "In Stock" if h.previous_warehouse else "Consumed"
                tracked.last_transaction = None
                tracked.last_movement_date = now()
                history.pop(i)
                break
        tracked.save(ignore_permissions=True)


def on_delivery_note_submit(doc, method):
    """Mark units on a delivered Delivery Note as Delivered (spec Test 7)."""
    for row in _tracked_rows(doc):
        tid = row.tracked_item
        if not tid or not frappe.db.exists("Tracked Item", tid):
            continue
        tracked = frappe.get_doc("Tracked Item", tid)
        prev_wh = tracked.current_warehouse
        tracked.append("item_tracking_history", {
            "transaction_type": "Delivery Note",
            "transaction_reference": doc.name,
            "previous_warehouse": prev_wh,
            "new_warehouse": None,
            "movement_date": now(),
            "performed_by": frappe.session.user,
        })
        tracked.current_warehouse = None
        tracked.current_status = "Delivered"
        tracked.last_transaction = doc.name
        tracked.last_movement_date = now()
        tracked.save(ignore_permissions=True)
