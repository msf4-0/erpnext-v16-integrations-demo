# -*- coding: utf-8 -*-
"""QR target page: /tracked_item_lookup?tracking_id=TRK-000001"""
from __future__ import unicode_literals

import frappe
from frappe.utils import get_url, cstr

no_cache = 1


def get_context(context):
    tracking_id = cstr(frappe.form_dict.get("tracking_id") or "").strip()
    context.tracking_id = tracking_id
    context.found = False
    context.item_name = None
    context.item_code = None
    context.current_warehouse = None
    context.current_status = None
    context.route = "#Form/Tracked Item/{0}".format(tracking_id)
    context.site = get_url()

    if not tracking_id:
        context.error = "No tracking ID supplied."
        return context

    tracked = frappe.db.get_value(
        "Tracked Item", {"name": tracking_id},
        ["name", "item_code", "item_name", "current_warehouse", "current_status", "serial_no"],
        as_dict=True,
    ) or frappe.db.get_value(
        "Tracked Item", {"barcode": tracking_id},
        ["name", "item_code", "item_name", "current_warehouse", "current_status", "serial_no"],
        as_dict=True,
    )

    if not tracked:
        context.error = "Tracked item {0} was not found.".format(tracking_id)
        return context

    history = frappe.get_all(
        "Item Tracking History",
        filters={"parent": tracked.get("name")},
        fields=["transaction_type", "transaction_reference", "previous_warehouse",
                "new_warehouse", "movement_date", "performed_by"],
        order_by="idx asc",
    )

    context.found = True
    context.tracking_id = tracked.get("name") or tracking_id
    context.serial_no = tracked.get("serial_no")
    context.item_name = tracked.item_name
    context.item_code = tracked.item_code
    context.current_warehouse = tracked.current_warehouse
    context.current_status = tracked.current_status
    context.history = history
    return context
