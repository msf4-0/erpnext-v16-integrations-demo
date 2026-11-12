# -*- coding: utf-8 -*-
"""Grouped tracker overview: one row per ITEM, not per unit.

Units stay individual (unique tracking_id + serial + barcode/QR), but this page
rolls them up under the product so the list is readable:
    WHL-001  Wheel   8 units   7 in stock   1 delivered   [open units]
"""
import frappe


def get_context(context):
    if frappe.session.user == "Guest":
        frappe.throw("Login required", frappe.PermissionError)

    context.no_cache = 1
    context.title = "Tracked Units by Item"
    context.groups = frappe.db.sql(
        """
        SELECT
            ti.item_code AS item_code,
            COALESCE(i.item_name, ti.item_code) AS item_name,
            COUNT(*) AS units,
            SUM(CASE WHEN ti.current_status = 'In Stock' THEN 1 ELSE 0 END) AS in_stock,
            SUM(CASE WHEN ti.current_status = 'Delivered' THEN 1 ELSE 0 END) AS delivered,
            SUM(CASE WHEN ti.current_status NOT IN ('In Stock', 'Delivered') THEN 1 ELSE 0 END) AS other,
            MIN(ti.serial_no) AS first_serial,
            MAX(ti.serial_no) AS last_serial,
            SUM(CASE WHEN ti.item_barcode IS NOT NULL AND ti.item_barcode != '' THEN 1 ELSE 0 END) AS with_item_barcode
        FROM `tabTracked Item` ti
        LEFT JOIN `tabItem` i ON i.name = ti.item_code
        GROUP BY ti.item_code, i.item_name
        ORDER BY i.item_name, ti.item_code
        """,
        as_dict=True,
    )
    context.total_units = sum(g.units or 0 for g in context.groups)
    return context
