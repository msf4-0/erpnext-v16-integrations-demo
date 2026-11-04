#!/usr/bin/env python3
"""Replace the coffee-shop demo items with a go-kart manufacturing demo.

Removes the "Copilot Demo" coffee/tea items (CPD-*) and seeds a small
go-kart build-to-stock scenario instead:

    Go-kart parts (Items)  ->  Go-kart BOM with routing operations  ->
    submitted Work Orders  ->  auto-created Job Cards

Idempotent: masters are ensured by name; Work Orders are skipped once any
go-kart Work Order already exists (pass --force-orders to add more).

Run inside the bench container:

    cd /home/frappe/frappe-bench && SITE_NAME=frontend \
        ./env/bin/python /tmp/seed_go_kart_demo.py [--force-orders]
"""
import json
import os
import sys
from datetime import timedelta

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")
COMPANY = os.environ.get("GO_KART_COMPANY", "SHRDC")
FORCE_ORDERS = "--force-orders" in sys.argv

# Copilot Demo coffee/tea items to remove (coffee-shop inventory).
COFFEE_ITEM_CODES = [
    "CPD-CHOC-1KG", "CPD-COFFEE-1KG", "CPD-CUP-12", "CPD-LID-100",
    "CPD-MILK-1L", "CPD-NAPKIN-500", "CPD-SYRUP-VAN", "CPD-TEA-500G",
]

# (item_code, item_name, is_finished_good)
GO_KART_ITEMS = [
    ("GK-KART", "Go-Kart (Complete)", True),
    ("GK-FRAME", "Go-Kart Chassis Frame", False),
    ("GK-WHEEL", "Go-Kart Wheel & Tire Assembly", False),
    ("GK-STEERING", "Go-Kart Steering Column", False),
    ("GK-SEAT", "Go-Kart Racing Seat", False),
    ("GK-ENGINE", "Go-Kart Engine 200cc", False),
    ("GK-AXLE", "Go-Kart Rear Axle", False),
    ("GK-BRAKE", "Go-Kart Brake System", False),
]

# Go-kart bill of materials: (item_code, qty).
GO_KART_BOM_ITEMS = [
    ("GK-FRAME", 1),
    ("GK-WHEEL", 4),
    ("GK-STEERING", 1),
    ("GK-SEAT", 1),
    ("GK-ENGINE", 1),
    ("GK-AXLE", 1),
    ("GK-BRAKE", 1),
]

# Routing for the finished go-kart: (operation, workstation, minutes).
GO_KART_OPERATIONS = [
    ("Cutting", "WS-CUTTING", 60),
    ("CNC Machining", "WS-CNC", 90),
    ("Assembly", "WS-ASSEMBLY", 120),
    ("Packing", "WS-PACKING", 30),
]

# Work Orders for the finished go-kart: (days ahead, quantity).
GO_KART_ORDER_PLAN = [
    (0, 5),
    (4, 10),
    (8, 8),
]


def log(msg):
    print("MARK %s" % msg)


def first_uom():
    if frappe.db.exists("UOM", "Nos"):
        return "Nos"
    name = frappe.db.get_value("UOM", {}, "name")
    if name:
        return name
    frappe.get_doc({"doctype": "UOM", "uom_name": "Nos", "enabled": 1}).insert(ignore_permissions=True)
    return "Nos"


def remove_coffee_items():
    removed, failed = [], []
    for code in COFFEE_ITEM_CODES:
        if not frappe.db.exists("Item", code):
            continue
        try:
            frappe.delete_doc("Item", code, ignore_permissions=True, force=1)
            removed.append(code)
        except Exception as exc:  # noqa: BLE001
            failed.append("%s (%s)" % (code, exc))
    frappe.db.commit()
    log("coffee items removed: %s" % (", ".join(removed) if removed else "none found"))
    if failed:
        log("coffee items FAILED to remove: %s" % ", ".join(failed))


def ensure_item(item_code, item_name, is_fg):
    if frappe.db.exists("Item", item_code):
        return item_code
    item_group = "Products" if frappe.db.exists("Item Group", "Products") else frappe.db.get_value("Item Group", {}, "name")
    item = frappe.get_doc(
        {
            "doctype": "Item",
            "item_code": item_code,
            "item_name": item_name,
            "item_group": item_group,
            "stock_uom": "Nos",
            "is_stock_item": 1,
            "is_sales_item": 1 if is_fg else 0,
            "is_purchase_item": 0 if is_fg else 1,
            "description": "Go-kart demo item",
        }
    )
    item.insert(ignore_permissions=True)
    log("item created: %s" % item_code)
    return item_code


def ensure_operation(name, workstation):
    if frappe.db.exists("Operation", name):
        return name
    doc = frappe.get_doc(
        {
            "doctype": "Operation",
            "name": name,
            "workstation": workstation,
            "description": "Go-kart demo operation",
        }
    )
    doc.insert(ignore_permissions=True)
    log("operation created: %s" % name)
    return name


def ensure_bom(item_code, operations, bom_items, uom):
    existing = frappe.db.get_value("BOM", {"item": item_code, "docstatus": 1}, "name")
    if existing:
        return existing

    currency = frappe.db.get_value("Company", COMPANY, "default_currency") or "MYR"
    bom = frappe.get_doc(
        {
            "doctype": "BOM",
            "item": item_code,
            "company": COMPANY,
            "quantity": 1,
            "uom": uom,
            "conversion_rate": 1,
            "currency": currency,
            "with_operations": 1,
            "items": [
                {"item_code": code, "qty": qty, "uom": uom, "stock_uom": uom}
                for code, qty in bom_items
            ],
            "operations": [
                {
                    "operation": op,
                    "workstation": ws,
                    "time_in_mins": mins,
                    "sequence_id": idx + 1,
                }
                for idx, (op, ws, mins) in enumerate(operations)
            ],
        }
    )
    bom.insert(ignore_permissions=True)
    bom.submit()
    log("bom submitted: %s (%.0f cost)" % (bom.name, bom.total_cost or 0))
    return bom.name


def warehouse_defaults():
    company = frappe.get_doc("Company", COMPANY)
    fg = company.get("default_fg_warehouse") or frappe.db.get_value(
        "Warehouse", {"warehouse_name": "Finished Goods", "company": COMPANY}, "name"
    )
    wip = company.get("default_wip_warehouse") or frappe.db.get_value(
        "Warehouse", {"warehouse_name": "Work In Progress", "company": COMPANY}, "name"
    )
    source = company.get("default_warehouse")
    return fg, wip, source


def create_work_order(item_code, bom_no, qty, days_ahead, uom, fg_wh, wip_wh, src_wh=None):
    from frappe.utils import now_datetime

    start_dt = now_datetime().replace(hour=8, minute=0, second=0, microsecond=0) + timedelta(days=days_ahead)
    doc = {
        "doctype": "Work Order",
        "production_item": item_code,
        "bom_no": bom_no,
        "qty": qty,
        "company": COMPANY,
        "stock_uom": uom,
        "planned_start_date": start_dt,
        "skip_transfer": 0,
    }
    if fg_wh:
        doc["fg_warehouse"] = fg_wh
    if wip_wh:
        doc["wip_warehouse"] = wip_wh
    if src_wh:
        doc["source_warehouse"] = src_wh

    wo = frappe.get_doc(doc)
    wo.set_work_order_operations()
    wo.insert(ignore_permissions=True)
    wo.submit()
    jc_count = frappe.db.count("Job Card", {"work_order": wo.name})
    log(
        "work order submitted: %s (%s x%s, %s ops, %s job cards)"
        % (wo.name, item_code, qty, len(wo.operations), jc_count)
    )
    return wo


def main():
    frappe.init(site=SITE, sites_path=".")
    frappe.connect()
    frappe.set_user("Administrator")

    if not frappe.db.exists("Company", COMPANY):
        raise SystemExit("ERROR: company %r does not exist on site %r" % (COMPANY, SITE))

    # 1. Remove the coffee-shop demo items.
    remove_coffee_items()

    # 2. Ensure operations exist (reuses the existing workstations' operations).
    for op, ws, _mins in GO_KART_OPERATIONS:
        ensure_operation(op, ws)

    # 3. Create go-kart items.
    for code, name, is_fg in GO_KART_ITEMS:
        ensure_item(code, name, is_fg)

    frappe.db.commit()

    # 4. Create + submit the go-kart BOM.
    bom_no = ensure_bom("GK-KART", GO_KART_OPERATIONS, GO_KART_BOM_ITEMS, "Nos")
    frappe.db.commit()

    # 5. Create + submit Work Orders (auto-creates Job Cards on submit).
    if frappe.db.exists("Work Order", {"production_item": "GK-KART"}) and not FORCE_ORDERS:
        log("go-kart Work Orders already exist - skipping (use --force-orders to add more)")
    else:
        fg_wh, wip_wh, src_wh = warehouse_defaults()
        log("warehouses: fg=%s wip=%s source=%s" % (fg_wh, wip_wh, src_wh))
        for days_ahead, qty in GO_KART_ORDER_PLAN:
            try:
                create_work_order("GK-KART", bom_no, qty, days_ahead, "Nos", fg_wh, wip_wh, src_wh)
            except Exception as exc:  # noqa: BLE001
                log("FAILED work order for GK-KART: %s" % exc)
                frappe.db.rollback()
        frappe.db.commit()

    summary = {
        "coffee_items_remaining": frappe.db.count("Item", {"item_code": ("like", "CPD-%")}),
        "go_kart_items": frappe.db.count("Item", {"item_code": ("like", "GK-%")}),
        "go_kart_boms": frappe.db.count("BOM", {"item": "GK-KART", "docstatus": 1}),
        "go_kart_work_orders": frappe.db.count("Work Order", {"production_item": "GK-KART"}),
        "go_kart_job_cards": len(
            frappe.get_all("Job Card", filters={"work_order": ("in", [wo.name for wo in frappe.get_all("Work Order", {"production_item": "GK-KART"})])})
        ),
    }
    print("SUMMARY " + json.dumps(summary, default=str))
    print("DONE")


if __name__ == "__main__":
    main()
