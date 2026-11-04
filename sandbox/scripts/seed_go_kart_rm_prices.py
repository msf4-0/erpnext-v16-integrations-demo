#!/usr/bin/env python3
"""Add raw materials + prices to the go-kart demo (multi-level BOM).

Turns the go-kart sub-assembly parts (frame, wheels, steering, seat, axle,
brake) into manufactured items with their own raw-material BOMs, and prices
every item in the demo:

    Raw materials (GK-RM-*)  ->  sub-assembly BOMs (GK-FRAME/WHEEL/...)  ->
    Go-Kart BOM (GK-KART)    ->  Work Orders / Job Cards (already seeded)

Prices are set as `standard_rate` on every item and as `rate` on every BOM
line, so the BOM total costs roll up correctly. Idempotent.

Run inside the bench container:

    cd /home/frappe/frappe-bench && SITE_NAME=frontend \
        ./env/bin/python /tmp/seed_go_kart_rm_prices.py
"""
import json
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")
COMPANY = os.environ.get("GO_KART_COMPANY", "SHRDC")

# Raw materials: (item_code, item_name, unit cost / standard_rate).
RM_ITEMS = [
    ("GK-RM-STEEL-TUBE", "Steel Tube (30mm x 6m)", 45.0),
    ("GK-RM-STEEL-PLATE", "Steel Plate (3mm)", 35.0),
    ("GK-RM-WELD-WIRE", "Welding Wire (MIG spool)", 8.0),
    ("GK-RM-RIM", "Wheel Rim (5 inch)", 25.0),
    ("GK-RM-TIRE", "Racing Tire (11x7)", 40.0),
    ("GK-RM-BEARING", "Ball Bearing (6201)", 6.0),
    ("GK-RM-STEER-SHAFT", "Steering Shaft", 30.0),
    ("GK-RM-STEER-WHEEL", "Steering Wheel", 35.0),
    ("GK-RM-TIE-ROD", "Tie Rod", 12.0),
    ("GK-RM-SEAT-SHELL", "Fiberglass Seat Shell", 55.0),
    ("GK-RM-FOAM", "Seat Foam Padding", 18.0),
    ("GK-RM-UPHOLSTERY", "Seat Upholstery (Vinyl)", 20.0),
    ("GK-RM-AXLE-SHAFT", "Rear Axle Shaft", 48.0),
    ("GK-RM-SPROCKET", "Drive Sprocket", 22.0),
    ("GK-RM-CALIPER", "Brake Caliper", 65.0),
    ("GK-RM-DISC", "Brake Disc", 28.0),
    ("GK-RM-PADS", "Brake Pads (set)", 12.0),
    ("GK-RM-CABLE", "Brake Cable", 15.0),
    ("GK-RM-MASTER", "Brake Master Cylinder", 38.0),
]

RM_PRICE = {code: price for code, _name, price in RM_ITEMS}

# Sub-assembly -> raw materials: (item_code, qty).
SUB_ASSEMBLY_BOMS = {
    "GK-FRAME": [("GK-RM-STEEL-TUBE", 2), ("GK-RM-STEEL-PLATE", 1), ("GK-RM-WELD-WIRE", 1)],
    "GK-WHEEL": [("GK-RM-RIM", 1), ("GK-RM-TIRE", 1), ("GK-RM-BEARING", 2)],
    "GK-STEERING": [("GK-RM-STEER-SHAFT", 1), ("GK-RM-STEER-WHEEL", 1), ("GK-RM-TIE-ROD", 1), ("GK-RM-BEARING", 2)],
    "GK-SEAT": [("GK-RM-SEAT-SHELL", 1), ("GK-RM-FOAM", 1), ("GK-RM-UPHOLSTERY", 1)],
    "GK-AXLE": [("GK-RM-AXLE-SHAFT", 1), ("GK-RM-SPROCKET", 1), ("GK-RM-BEARING", 2)],
    "GK-BRAKE": [("GK-RM-CALIPER", 1), ("GK-RM-DISC", 1), ("GK-RM-PADS", 1), ("GK-RM-CABLE", 1), ("GK-RM-MASTER", 1)],
}

# Selling price (standard_rate) of each manufactured sub-assembly.
SUB_SELLING = {
    "GK-FRAME": 180.0,
    "GK-WHEEL": 95.0,
    "GK-STEERING": 120.0,
    "GK-SEAT": 120.0,
    "GK-AXLE": 105.0,
    "GK-BRAKE": 200.0,
}

# Purchased component (kept as a bought-in part) and the finished kart.
ENGINE_COST = 850.0
KART_SELLING = 2500.0


def log(msg):
    print("MARK %s" % msg)


def sub_cost(items):
    return sum(RM_PRICE[rm] * qty for rm, qty in items)


def ensure_rm_item(code, name, price):
    if frappe.db.exists("Item", code):
        return code
    item_group = "Products" if frappe.db.exists("Item Group", "Products") else frappe.db.get_value("Item Group", {}, "name")
    item = frappe.get_doc(
        {
            "doctype": "Item",
            "item_code": code,
            "item_name": name,
            "item_group": item_group,
            "stock_uom": "Nos",
            "is_stock_item": 1,
            "is_sales_item": 0,
            "is_purchase_item": 1,
            "standard_rate": price,
            "valuation_rate": price,
            "description": "Go-kart raw material",
        }
    )
    item.insert(ignore_permissions=True)
    log("raw material created: %s (RM %.2f)" % (code, price))
    return code


def set_price(item_code, standard_rate, is_purchase=None, is_sales=None):
    item = frappe.get_doc("Item", item_code)
    item.standard_rate = standard_rate
    if is_purchase is not None:
        item.is_purchase_item = is_purchase
    if is_sales is not None:
        item.is_sales_item = is_sales
    item.save(ignore_permissions=True)
    return item


def ensure_sub_bom(item_code, items):
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
            "uom": "Nos",
            "conversion_rate": 1,
            "currency": currency,
            "with_operations": 0,
            "items": [
                {"item_code": rm, "qty": qty, "uom": "Nos", "stock_uom": "Nos", "rate": RM_PRICE[rm]}
                for rm, qty in items
            ],
        }
    )
    bom.insert(ignore_permissions=True)
    bom.submit()
    log("sub-assembly BOM submitted: %s (cost %.2f)" % (bom.name, bom.total_cost or 0))
    return bom.name


def main():
    frappe.init(site=SITE, sites_path=".")
    frappe.connect()
    frappe.set_user("Administrator")

    if not frappe.db.exists("Company", COMPANY):
        raise SystemExit("ERROR: company %r does not exist on site %r" % (COMPANY, SITE))

    # 1. Raw materials.
    for code, name, price in RM_ITEMS:
        ensure_rm_item(code, name, price)
    frappe.db.commit()

    # 2. Sub-assemblies -> manufactured, with a selling price.
    for code, price in SUB_SELLING.items():
        set_price(code, price, is_purchase=0, is_sales=1)
    frappe.db.commit()

    # 3. Engine (bought-in) + finished kart selling prices.
    set_price("GK-ENGINE", ENGINE_COST, is_purchase=1, is_sales=0)
    set_price("GK-KART", KART_SELLING, is_purchase=0, is_sales=1)
    frappe.db.commit()

    # 4. Sub-assembly BOMs (raw materials).
    for code, items in SUB_ASSEMBLY_BOMS.items():
        ensure_sub_bom(code, items)
    frappe.db.commit()

    # 5. Price the finished Go-Kart BOM's component lines and re-submit so the
    #    cost and the multi-level explosion reflect the sub-assemblies.
    kart_bom_name = frappe.db.get_value("BOM", {"item": "GK-KART", "docstatus": 1}, "name")
    kart_rates = {code: sub_cost(items) for code, items in SUB_ASSEMBLY_BOMS.items()}
    kart_rates["GK-ENGINE"] = ENGINE_COST

    if kart_bom_name:
        bom = frappe.get_doc("BOM", kart_bom_name)
        if bom.docstatus == 1:
            bom.cancel()
            bom = frappe.get_doc("BOM", kart_bom_name)
        for row in bom.items:
            rate = kart_rates.get(row.item_code)
            if rate is not None:
                row.rate = rate
        bom.save(ignore_permissions=True)
        bom.submit()
        log("kart BOM re-submitted: %s (cost %.2f)" % (bom.name, bom.total_cost or 0))
        frappe.db.commit()

    # 6. Report.
    prices = {
        code: frappe.db.get_value("Item", code, "standard_rate")
        for code in ["GK-KART", "GK-ENGINE"] + list(SUB_SELLING) + [c for c, _n, _p in RM_ITEMS]
    }
    boms = {
        b.item: frappe.db.get_value("BOM", {"item": b.item, "docstatus": 1}, "total_cost")
        for b in frappe.get_all("BOM", filters={"docstatus": 1, "item": ["like", "GK-%"]}, fields=["item"])
    }
    summary = {
        "rm_items": frappe.db.count("Item", {"item_code": ["like", "GK-RM-%"]}),
        "sub_assembly_boms": len(SUB_ASSEMBLY_BOMS),
        "kart_bom_cost": frappe.db.get_value("BOM", {"item": "GK-KART", "docstatus": 1}, "total_cost"),
        "prices": prices,
        "bom_costs": boms,
    }
    print("SUMMARY " + json.dumps(summary, default=str))
    print("DONE")


if __name__ == "__main__":
    main()
