#!/usr/bin/env python3
"""Finalize new go-kart demo: link operations -> workstations, drop stale old demo.

Run inside the bench container:
    cd /home/frappe/frappe-bench && SITE_NAME=frontend \
        ./env/bin/python /tmp/finalize_new_go_kart.py
"""
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")

NEW_OPS = {
    "Painting": "S5- Painting",
    "Assembly": "S6- Assembly",
    "QC": "S7- QC",
}
STALE_OPS = ["Cutting", "CNC Machining", "Packing"]
STALE_WORKSTATIONS = ["WS-CUTTING", "WS-CNC", "WS-ASSEMBLY", "WS-PACKING"]


def q(sql_, *a):
    return frappe.db.sql(sql_, a)


def refs_op(op):
    n = 0
    for t, f in [("BOM Operation", "operation"), ("Work Order Operation", "operation"), ("Job Card", "operation")]:
        try:
            n += q("SELECT COUNT(*) FROM `tab%s` WHERE %s=%%s" % (t, f), op)[0][0]
        except Exception:  # noqa: BLE001
            pass
    return n


def refs_ws(ws):
    n = 0
    for t, f in [("Operation", "workstation"), ("BOM Operation", "workstation"),
                 ("Work Order Operation", "workstation"), ("Job Card", "workstation")]:
        try:
            n += q("SELECT COUNT(*) FROM `tab%s` WHERE %s=%%s" % (t, f), ws)[0][0]
        except Exception:  # noqa: BLE001
            pass
    return n


def main():
    frappe.init(site=SITE, sites_path=".")
    frappe.connect()
    frappe.set_user("Administrator")

    # 1. Link the three operations to their new workstations.
    for op, ws in NEW_OPS.items():
        if frappe.db.exists("Operation", op):
            frappe.db.set_value("Operation", op, "workstation", ws)
            frappe.db.set_value("Operation", op, "description", "Go-kart demo operation")
            print("linked Operation %s -> %s" % (op, ws))
        else:
            frappe.get_doc({"doctype": "Operation", "name": op, "workstation": ws,
                            "description": "Go-kart demo operation"}).insert(ignore_permissions=True)
            print("created Operation %s -> %s" % (op, ws))

    # 2. Drop stale old go-kart operations (orphaned only).
    for op in STALE_OPS:
        if frappe.db.exists("Operation", op) and refs_op(op) == 0:
            frappe.delete_doc("Operation", op, ignore_permissions=True, force=1)
            print("deleted stale Operation %s" % op)
        elif frappe.db.exists("Operation", op):
            print("kept Operation %s (still referenced %d)" % (op, refs_op(op)))

    # 3. Drop stale old go-kart workstations (orphaned only).
    for ws in STALE_WORKSTATIONS:
        if frappe.db.exists("Workstation", ws) and refs_ws(ws) == 0:
            frappe.delete_doc("Workstation", ws, ignore_permissions=True, force=1)
            print("deleted stale Workstation %s" % ws)
        elif frappe.db.exists("Workstation", ws):
            print("kept Workstation %s (still referenced %d)" % (ws, refs_ws(ws)))

    frappe.db.commit()

    print("\n=== FINAL STATE ===")
    print("Items:")
    for c in ["GKRT-001", "WHL-001", "HST-001", "SET-001", "FRM-001", "STR-001"]:
        it = frappe.db.get_value("Item", c, ["item_name", "item_group", "standard_rate", "has_serial_no", "serial_no_series"], as_dict=1)
        bc = frappe.db.get_value("Item Barcode", {"parent": c}, "barcode")
        print("  %s | %s | %s | %.2f | serial=%s %s | barcode=%s" % (c, it["item_name"], it["item_group"], it["standard_rate"], it["has_serial_no"], it["serial_no_series"], bc))
    print("Workstations:")
    for ws in ["S5- Painting", "S6- Assembly", "S7- QC"]:
        print("  %s (exists=%s)" % (ws, frappe.db.exists("Workstation", ws)))
    print("Operations:")
    for op in ["Painting", "Assembly", "QC"]:
        print("  %s -> %s" % (op, frappe.db.get_value("Operation", op, "workstation")))
    print("DONE")


if __name__ == "__main__":
    main()
