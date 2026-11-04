#!/usr/bin/env python3
"""Create + submit the Go Kart BOM (GKRT-001) with Painting -> Assembly -> QC routing.

Components (one go-kart):
    Frame FRM-001 x1, Wheel WHL-001 x4, Handling HST-001 x1, Seat SET-001 x1, Steering STR-001 x1

Idempotent: reuses an existing submitted BOM if present.

Run inside the bench container:
    cd /home/frappe/frappe-bench && SITE_NAME=frontend \
        ./env/bin/python /tmp/seed_new_go_kart_bom.py
"""
import json
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")
COMPANY = os.environ.get("GO_KART_COMPANY", "SHRDC")

FG_ITEM = "GKRT-001"

# (item_code, qty)
COMPONENTS = [
    ("FRM-001", 1),
    ("WHL-001", 4),
    ("HST-001", 1),
    ("SET-001", 1),
    ("STR-001", 1),
]

# (operation, workstation, minutes)
OPERATIONS = [
    ("Painting", "S5- Painting", 30),
    ("Assembly", "S6- Assembly", 60),
    ("QC", "S7- QC", 15),
]


def main():
    frappe.init(site=SITE, sites_path=".")
    frappe.connect()
    frappe.set_user("Administrator")

    if not frappe.db.exists("Item", FG_ITEM):
        raise SystemExit("ERROR: finished good %r not found" % FG_ITEM)

    existing = frappe.db.get_value("BOM", {"item": FG_ITEM, "docstatus": 1}, "name")
    if existing:
        print("BOM already exists: %s (total cost %s)" % (existing, frappe.db.get_value("BOM", existing, "total_cost")))
        print("DONE")
        return

    currency = frappe.db.get_value("Company", COMPANY, "default_currency") or "MYR"

    bom = frappe.get_doc({
        "doctype": "BOM",
        "item": FG_ITEM,
        "company": COMPANY,
        "quantity": 1,
        "uom": "Nos",
        "conversion_rate": 1,
        "currency": currency,
        "is_default": 1,
        "with_operations": 1,
        "items": [
            {
                "item_code": code,
                "qty": qty,
                "uom": "Nos",
                "stock_uom": "Nos",
                "conversion_factor": 1,
                "rate": frappe.db.get_value("Item", code, "standard_rate") or 0,
                "amount": (frappe.db.get_value("Item", code, "standard_rate") or 0) * qty,
            }
            for code, qty in COMPONENTS
        ],
        "operations": [
            {
                "operation": op,
                "workstation": ws,
                "time_in_mins": mins,
                "sequence_id": idx + 1,
            }
            for idx, (op, ws, mins) in enumerate(OPERATIONS)
        ],
    })
    bom.insert(ignore_permissions=True)
    bom.submit()

    # Point the item at this BOM as default (required for SO -> Work Order).
    frappe.db.set_value("BOM", bom.name, "is_default", 1)
    frappe.db.set_value("Item", FG_ITEM, "default_bom", bom.name)
    frappe.db.commit()

    print("BOM submitted: %s (total cost %.2f)" % (bom.name, bom.total_cost or 0))
    print("SUMMARY " + json.dumps({
        "bom": bom.name,
        "item": FG_ITEM,
        "total_cost": bom.total_cost,
        "components": COMPONENTS,
        "operations": [op for op, _ws, _m in OPERATIONS],
    }, default=str))
    print("DONE")


if __name__ == "__main__":
    main()
