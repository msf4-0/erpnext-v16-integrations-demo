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


def on_stock_entry_submit(doc, method):
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
