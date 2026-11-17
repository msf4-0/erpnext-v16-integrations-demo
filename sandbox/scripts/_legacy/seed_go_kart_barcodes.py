#!/usr/bin/env python3
"""Add barcodes + QR-ready labels to every go-kart part, and finalise the
Go-Kart BOM cost.

Three things here:

1.  Fix the finished Go-Kart BOM (BOM-GK-KART-001) component `rate` / `amount`
    and `total_cost` directly.  A Sales Order is linked to that BOM, so it
    cannot be cancelled + re-submitted; the rates are written in place instead.
2.  Give every go-kart item (finished kart + sub-assemblies + raw materials) its
    own unique barcode in the Item -> Barcodes table (blank type = Code128).
3.  Create a "Barcode Printing" document listing all parts so the barcode_shrdc
    app can render both the linear barcode and the per-item QR code (the QR
    encodes the item_qr route -> item_code + barcode).

Idempotent. Run inside the bench container:

    cd /home/frappe/frappe-bench && SITE_NAME=frontend \
        ./env/bin/python /tmp/seed_go_kart_barcodes.py
"""
import json
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")
COMPANY = os.environ.get("GO_KART_COMPANY", "SHRDC")

# Sub-assembly -> raw materials: (item_code, qty).  Mirrors seed_go_kart_rm_prices.
SUB_ASSEMBLY_BOMS = {
    "GK-FRAME": [("GK-RM-STEEL-TUBE", 2), ("GK-RM-STEEL-PLATE", 1), ("GK-RM-WELD-WIRE", 1)],
    "GK-WHEEL": [("GK-RM-RIM", 1), ("GK-RM-TIRE", 1), ("GK-RM-BEARING", 2)],
    "GK-STEERING": [("GK-RM-STEER-SHAFT", 1), ("GK-RM-STEER-WHEEL", 1), ("GK-RM-TIE-ROD", 1), ("GK-RM-BEARING", 2)],
    "GK-SEAT": [("GK-RM-SEAT-SHELL", 1), ("GK-RM-FOAM", 1), ("GK-RM-UPHOLSTERY", 1)],
    "GK-AXLE": [("GK-RM-AXLE-SHAFT", 1), ("GK-RM-SPROCKET", 1), ("GK-RM-BEARING", 2)],
    "GK-BRAKE": [("GK-RM-CALIPER", 1), ("GK-RM-DISC", 1), ("GK-RM-PADS", 1), ("GK-RM-CABLE", 1), ("GK-RM-MASTER", 1)],
}

ENGINE_COST = 850.0


def log(msg):
    print("MARK %s" % msg)


def sub_cost(items):
    return sum(frappe.db.get_value("Item", rm, "standard_rate") * qty for rm, qty in items)


def fix_kart_bom_cost():
    bom_name = frappe.db.get_value("BOM", {"item": "GK-KART", "docstatus": 1}, "name")
    if not bom_name:
        log("no submitted GK-KART BOM found - skipping cost fix")
        return
    rates = {code: sub_cost(items) for code, items in SUB_ASSEMBLY_BOMS.items()}
    rates["GK-ENGINE"] = ENGINE_COST

    total = 0.0
    for row in frappe.get_all("BOM Item", filters={"parent": bom_name}, fields=["name", "item_code", "qty"]):
        rate = rates.get(row.item_code)
        if rate is None:
            continue
        amount = rate * row.qty
        frappe.db.set_value("BOM Item", row.name, {"rate": rate, "amount": amount})
        total += amount
    frappe.db.set_value("BOM", bom_name, "total_cost", total)
    frappe.db.commit()
    log("kart BOM cost fixed: %s -> %.2f" % (bom_name, total))


def add_item_barcodes():
    items = frappe.get_all("Item", filters={"item_code": ["like", "GK-%"]}, fields=["name", "item_code", "item_name"], order_by="item_code")
    added, skipped = 0, 0
    for it in items:
        code = it["item_code"]
        if frappe.db.exists("Item Barcode", {"parent": it["name"], "barcode": code}):
            skipped += 1
            continue
        doc = frappe.get_doc("Item", it["name"])
        doc.append("barcodes", {"barcode": code, "barcode_type": ""})
        doc.save(ignore_permissions=True)
        added += 1
    frappe.db.commit()
    log("item barcodes added: %d (skipped %d existing)" % (added, skipped))
    return items


def create_barcode_printing(items):
    existing = frappe.db.sql(
        "select distinct parent from `tabBarcode Generator Items` where item_code like 'GK-%' limit 1"
    )
    if existing:
        name = existing[0][0]
        log("go-kart barcode printing doc already exists (%s) - skipping" % name)
        return name

    rows = []
    for it in items:
        rate = frappe.db.get_value("Item", it["name"], "standard_rate") or 0
        rows.append({
            "item_code": it["item_code"],
            "item_name": it["item_name"],
            "barcode": it["item_code"],
            "barcode_type": "CODE128",
            "qty": 1,
            "uom": "Nos",
            "rate": rate,
            "basic_rate": rate,
            "conversion_factor": 1,
            "warehouse": "Stores - " + COMPANY,
        })

    doc = frappe.get_doc({
        "doctype": "Barcode Printing",
        "naming_series": "BP-.YYYY.-.MM.-.DD.-",
        "company": COMPANY,
        "show_sku": 1,
        "items": rows,
    })
    doc.insert(ignore_permissions=True)
    frappe.db.commit()
    log("barcode printing doc created: %s (%d parts)" % (doc.name, len(rows)))
    return doc.name


def main():
    frappe.init(site=SITE, sites_path=".")
    frappe.connect()
    frappe.set_user("Administrator")

    if not frappe.db.exists("Company", COMPANY):
        raise SystemExit("ERROR: company %r does not exist on site %r" % (COMPANY, SITE))

    fix_kart_bom_cost()
    items = add_item_barcodes()
    bp_name = create_barcode_printing(items)

    summary = {
        "kart_bom_cost": frappe.db.get_value("BOM", {"item": "GK-KART", "docstatus": 1}, "total_cost"),
        "items_with_barcode": frappe.db.count("Item Barcode", {"parent": ["like", "GK-%"]}),
        "barcode_printing_doc": bp_name,
        "go_kart_items": len(items),
    }
    print("SUMMARY " + json.dumps(summary, default=str))
    print("DONE")


if __name__ == "__main__":
    main()
