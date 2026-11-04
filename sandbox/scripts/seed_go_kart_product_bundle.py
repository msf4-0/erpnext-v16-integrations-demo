#!/usr/bin/env python3
"""Create a Product Bundle that expands into all go-kart raw materials.

"GK-RM-KIT" (Go-Kart Raw Material Kit) is a non-stock bundle item. Adding it to
a Material Request / Purchase Order / Purchase Receipt expands into the full raw
material list (19 RM items + engine) in the quantities needed for ONE kart.

Idempotent. Run inside the bench container:

    cd /home/frappe/frappe-bench && SITE_NAME=frontend \
        ./env/bin/python /tmp/seed_go_kart_product_bundle.py
"""
import json
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")
COMPANY = os.environ.get("GO_KART_COMPANY", "SHRDC")

BUNDLE_ITEM = "GK-RM-KIT"

# (item_code, qty) for exactly ONE go-kart.
RM_KIT_ITEMS = [
    ("GK-RM-STEEL-TUBE", 2),
    ("GK-RM-STEEL-PLATE", 1),
    ("GK-RM-WELD-WIRE", 1),
    ("GK-RM-RIM", 4),
    ("GK-RM-TIRE", 4),
    ("GK-RM-BEARING", 12),
    ("GK-RM-STEER-SHAFT", 1),
    ("GK-RM-STEER-WHEEL", 1),
    ("GK-RM-TIE-ROD", 1),
    ("GK-RM-SEAT-SHELL", 1),
    ("GK-RM-FOAM", 1),
    ("GK-RM-UPHOLSTERY", 1),
    ("GK-RM-AXLE-SHAFT", 1),
    ("GK-RM-SPROCKET", 1),
    ("GK-RM-CALIPER", 1),
    ("GK-RM-DISC", 1),
    ("GK-RM-PADS", 1),
    ("GK-RM-CABLE", 1),
    ("GK-RM-MASTER", 1),
    ("GK-ENGINE", 1),
]


def log(msg):
    print("MARK %s" % msg)


def ensure_parent_item():
    if frappe.db.exists("Item", BUNDLE_ITEM):
        return BUNDLE_ITEM
    item_group = "Products" if frappe.db.exists("Item Group", "Products") else frappe.db.get_value("Item Group", {}, "name")
    frappe.get_doc({
        "doctype": "Item",
        "item_code": BUNDLE_ITEM,
        "item_name": "Go-Kart Raw Material Kit",
        "item_group": item_group,
        "stock_uom": "Nos",
        "is_stock_item": 0,
        "is_sales_item": 0,
        "is_purchase_item": 1,
        "description": "Product bundle: all raw materials + engine for one go-kart",
    }).insert(ignore_permissions=True)
    log("bundle item created: %s" % BUNDLE_ITEM)
    return BUNDLE_ITEM


def ensure_product_bundle():
    if frappe.db.exists("Product Bundle", BUNDLE_ITEM):
        log("product bundle already exists: %s" % BUNDLE_ITEM)
        return BUNDLE_ITEM
    frappe.get_doc({
        "doctype": "Product Bundle",
        "new_item_code": BUNDLE_ITEM,
        "description": "Go-Kart Raw Material Kit (all RM for 1 kart)",
        "items": [
            {"item_code": code, "qty": qty, "uom": "Nos", "description": frappe.db.get_value("Item", code, "item_name")}
            for code, qty in RM_KIT_ITEMS
        ],
    }).insert(ignore_permissions=True)
    frappe.db.commit()
    log("product bundle created: %s (%d components)" % (BUNDLE_ITEM, len(RM_KIT_ITEMS)))
    return BUNDLE_ITEM


def main():
    frappe.init(site=SITE, sites_path=".")
    frappe.connect()
    frappe.set_user("Administrator")

    ensure_parent_item()
    ensure_product_bundle()

    summary = {
        "bundle_item": BUNDLE_ITEM,
        "bundle_exists": frappe.db.exists("Product Bundle", BUNDLE_ITEM),
        "components": len(RM_KIT_ITEMS),
        "component_rows": frappe.db.count("Product Bundle Item", {"parent": BUNDLE_ITEM}),
    }
    print("SUMMARY " + json.dumps(summary, default=str))
    print("DONE")


if __name__ == "__main__":
    main()
