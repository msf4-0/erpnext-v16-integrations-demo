#!/usr/bin/env python3
"""Seed the NEW go-kart demo (post-cleanup) per the supplied spec.

    Items (6):
      Go Kart    GKRT-001   Product        Nos   RM1,000.00 (Standard Selling)  9222876361011  GKRT.####
      Wheel      WHL-001    Raw Material   Nos   RM50.00    (Standard Buying)   9221234561018  WHLS.####
      Handling   HST-001    Raw Material   Nos   RM150.00   (Standard Buying)   9221211161019  HSTS.####
      Seat       SET-001    Raw Material   Nos   RM30.00    (Standard Buying)   9221222261012  SEAT.####
      Frame      FRM-001    Raw Material   Nos   RM250.00   (Standard Buying)   9221333361014  FRMS.####
      Steering   STR-001    Raw Material   Nos   RM50.00    (Standard Buying)   9221444461016  STRG.####

    Workstations (Operation / Routing):
      S5- Painting, S6- Assembly, S7- QC  (+ matching Operations Painting/Assembly/QC)

Idempotent. Run inside the bench container:
    cd /home/frappe/frappe-bench && SITE_NAME=frontend \
        ./env/bin/python /tmp/seed_new_go_kart.py
"""
import json
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")
COMPANY = os.environ.get("GO_KART_COMPANY", "SHRDC")

# (item_code, item_name, item_group, standard_rate, price_list, barcode, serial_series, is_fg)
ITEMS = [
    ("GKRT-001", "Go Kart", "Product", 1000.00, "Standard Selling", "9222876361011", "GKRT.####", True),
    ("WHL-001", "Wheel", "Raw Material", 50.00, "Standard Buying", "9221234561018", "WHLS.####", False),
    ("HST-001", "Handling", "Raw Material", 150.00, "Standard Buying", "9221211161019", "HSTS.####", False),
    ("SET-001", "Seat", "Raw Material", 30.00, "Standard Buying", "9221222261012", "SEAT.####", False),
    ("FRM-001", "Frame", "Raw Material", 250.00, "Standard Buying", "9221333361014", "FRMS.####", False),
    ("STR-001", "Steering", "Raw Material", 50.00, "Standard Buying", "9221444461016", "STRG.####", False),
]

# (workstation_name, operation_name)
WORKSTATIONS = [
    ("S5- Painting", "Painting"),
    ("S6- Assembly", "Assembly"),
    ("S7- QC", "QC"),
]


def log(msg):
    print(msg)


def ensure_item_group(name):
    if frappe.db.exists("Item Group", name):
        return name
    parent = "All Item Groups" if frappe.db.exists("Item Group", "All Item Groups") else None
    doc = frappe.get_doc({"doctype": "Item Group", "item_group_name": name, "is_group": 0})
    if parent:
        doc.parent_item_group = parent
    doc.insert(ignore_permissions=True)
    log("item group created: %s" % name)
    return name


def ensure_item(code, name, group, rate, price_list, barcode, serial, is_fg):
    group = ensure_item_group(group)
    existing = frappe.db.exists("Item", code)
    if not existing:
        doc = frappe.get_doc({
            "doctype": "Item",
            "item_code": code,
            "item_name": name,
            "item_group": group,
            "stock_uom": "Nos",
            "is_stock_item": 1,
            "has_serial_no": 1,
            "serial_no_series": serial,
            "is_sales_item": 1 if is_fg else 0,
            "is_purchase_item": 0 if is_fg else 1,
            "standard_rate": rate,
            "valuation_rate": rate,
            "description": "%s (go-kart demo item)" % name,
            "barcodes": [{"barcode": barcode, "barcode_type": ""}],
        })
        doc.insert(ignore_permissions=True)
        log("item created: %s" % code)
    else:
        doc = frappe.get_doc("Item", code)
        doc.standard_rate = rate
        doc.has_serial_no = 1
        doc.serial_no_series = serial
        doc.is_sales_item = 1 if is_fg else 0
        doc.is_purchase_item = 0 if is_fg else 1
        if not any(b.barcode == barcode for b in doc.barcodes):
            doc.append("barcodes", {"barcode": barcode, "barcode_type": ""})
        doc.save(ignore_permissions=True)
        log("item updated: %s" % code)

    # Item Price in the right list.
    currency = frappe.db.get_value("Company", COMPANY, "default_currency") or "MYR"
    is_selling = price_list == "Standard Selling"
    if frappe.db.exists("Item Price", {"item_code": code, "price_list": price_list}):
        ip = frappe.get_doc("Item Price", {"item_code": code, "price_list": price_list})
        ip.price_list_rate = rate
        ip.save(ignore_permissions=True)
    else:
        frappe.get_doc({
            "doctype": "Item Price",
            "item_code": code,
            "uom": "Nos",
            "price_list": price_list,
            "price_list_rate": rate,
            "currency": currency,
            "selling": 1 if is_selling else 0,
            "buying": 0 if is_selling else 1,
        }).insert(ignore_permissions=True)
    return code


def ensure_workstation(ws_name, op_name):
    if not frappe.db.exists("Workstation", ws_name):
        frappe.get_doc({"doctype": "Workstation", "workstation_name": ws_name}).insert(ignore_permissions=True)
        log("workstation created: %s" % ws_name)
    if not frappe.db.exists("Operation", op_name):
        frappe.get_doc({
            "doctype": "Operation",
            "name": op_name,
            "workstation": ws_name,
            "description": "Go-kart demo operation",
        }).insert(ignore_permissions=True)
        log("operation created: %s" % op_name)


def main():
    frappe.init(site=SITE, sites_path=".")
    frappe.connect()
    frappe.set_user("Administrator")

    if not frappe.db.exists("Company", COMPANY):
        raise SystemExit("ERROR: company %r not found" % COMPANY)

    # Serial numbers are required by the spec; enable the global toggle.
    frappe.db.set_value("Stock Settings", "Stock Settings", "enable_serial_and_batch_no_for_item", 1)
    frappe.db.commit()
    log("Stock Settings: serial/batch activation enabled")

    # Precondition: assert old GK-* data is gone.
    leftover = frappe.db.count("Item", {"item_code": ["like", "GK-%"]})
    if leftover:
        log("WARNING: %d GK-* items still present (cleanup incomplete)" % leftover)

    for code, name, group, rate, pl, barcode, serial, is_fg in ITEMS:
        ensure_item(code, name, group, rate, pl, barcode, serial, is_fg)
    frappe.db.commit()

    for ws_name, op_name in WORKSTATIONS:
        ensure_workstation(ws_name, op_name)
    frappe.db.commit()

    summary = {
        "items": {code: frappe.db.get_value("Item", code, "standard_rate") for code, *_ in ITEMS},
        "item_prices": {
            code: frappe.db.get_value("Item Price", {"item_code": code}, "price_list_rate")
            for code, *_ in ITEMS
        },
        "workstations": [ws for ws, _ in WORKSTATIONS],
        "operations": [op for _, op in WORKSTATIONS],
    }
    print("SUMMARY " + json.dumps(summary, default=str))
    print("DONE")


if __name__ == "__main__":
    main()
