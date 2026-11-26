#!/usr/bin/env python3
"""Seed opening stock (Material Receipt) for the 5 serialized raw-material parts.

Receives into the company default warehouse with serial numbers so the parts
can be issued to the Go Kart Work Order.

Run inside the bench container:
    cd /home/frappe/frappe-bench && SITE_NAME=frontend \
        ./env/bin/python /tmp/seed_rm_opening_stock.py
"""
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")
# The item_tracking custom app is half-installed (not on sys.path) but adds a
# child table to Stock Entry; without this its module can't be imported.
sys.path.insert(0, "/home/frappe/frappe-bench/apps/item_tracking")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")
COMPANY = os.environ.get("GO_KART_COMPANY", "SHRDC")

# (item_code, qty, [serial numbers])
PARTS = [
    ("FRM-001", 1, ["FRMS.0001"]),
    ("WHL-001", 4, ["WHLS.0001", "WHLS.0002", "WHLS.0003", "WHLS.0004"]),
    ("HST-001", 1, ["HSTS.0001"]),
    ("SET-001", 1, ["SEAT.0001"]),
    ("STR-001", 1, ["STRG.0001"]),
]


def main():
    frappe.init(site=SITE, sites_path=".")
    frappe.connect()
    frappe.set_user("Administrator")

    wh = frappe.db.get_value("Company", COMPANY, "default_warehouse")
    if not wh:
        wh = frappe.db.get_value("Warehouse", {"company": COMPANY}, "name")
    print("target warehouse: %s" % wh)

    # Skip if already seeded (any of these serials exists).
    if frappe.db.exists("Serial No", "FRMS.0001") or frappe.db.exists("Serial No", "WHLS.0001"):
        print("opening stock already present - skipping")
        print("DONE")
        return

    items = []
    for code, qty, serials in PARTS:
        if not frappe.db.exists("Item", code):
            raise SystemExit("ERROR: item %r not found" % code)
        items.append({
            "item_code": code,
            "qty": qty,
            "t_warehouse": wh,
            "serial_no": "\n".join(serials),
            "conversion_factor": 1,
        })

    se = frappe.get_doc({
        "doctype": "Stock Entry",
        "stock_entry_type": "Material Receipt",
        "company": COMPANY,
        "to_warehouse": wh,
        "items": items,
    })
    se.insert(ignore_permissions=True)
    se.submit()
    frappe.db.commit()

    print("Material Receipt submitted: %s" % se.name)
    for code, qty, serials in PARTS:
        print("  %s x%d -> %s" % (code, qty, ", ".join(serials)))

    # Verify stock.
    print("\nCurrent stock (per warehouse bin):")
    for code, _qty, _s in PARTS:
        bins = frappe.get_all("Bin", filters={"item_code": code}, fields=["warehouse", "actual_qty"])
        for b in bins:
            print("  %s @ %s = %s" % (code, b["warehouse"], b["actual_qty"]))
    print("DONE")


if __name__ == "__main__":
    main()
