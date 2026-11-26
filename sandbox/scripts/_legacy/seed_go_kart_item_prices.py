#!/usr/bin/env python3
"""Create Price List entries (Item Price) for every go-kart item.

`standard_rate` on the Item is the master/valuation rate, but the price that
shows on Quotations, Sales Orders, Delivery Notes and the Item Price list is an
**Item Price** (Price List) record. This script links every go-kart part to a
price in the right list:

    Standard Selling  ->  finished kart + sub-assemblies + engine (selling price)
    Standard Buying   ->  raw materials + engine (purchase cost)

Idempotent: skips any item already priced in a given list.

Run inside the bench container:

    cd /home/frappe/frappe-bench && SITE_NAME=frontend \
        ./env/bin/python /tmp/seed_go_kart_item_prices.py
"""
import json
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")
SELLING_PL = "Standard Selling"
BUYING_PL = "Standard Buying"

# Selling prices (Standard Selling price list).
SELLING_PRICES = {
    "GK-KART": 2500.0,
    "GK-FRAME": 180.0,
    "GK-WHEEL": 95.0,
    "GK-STEERING": 120.0,
    "GK-SEAT": 120.0,
    "GK-AXLE": 105.0,
    "GK-BRAKE": 200.0,
    "GK-ENGINE": 950.0,
}

# Purchase costs (Standard Buying price list).
BUYING_PRICES = {
    "GK-RM-STEEL-TUBE": 45.0,
    "GK-RM-STEEL-PLATE": 35.0,
    "GK-RM-WELD-WIRE": 8.0,
    "GK-RM-RIM": 25.0,
    "GK-RM-TIRE": 40.0,
    "GK-RM-BEARING": 6.0,
    "GK-RM-STEER-SHAFT": 30.0,
    "GK-RM-STEER-WHEEL": 35.0,
    "GK-RM-TIE-ROD": 12.0,
    "GK-RM-SEAT-SHELL": 55.0,
    "GK-RM-FOAM": 18.0,
    "GK-RM-UPHOLSTERY": 20.0,
    "GK-RM-AXLE-SHAFT": 48.0,
    "GK-RM-SPROCKET": 22.0,
    "GK-RM-CALIPER": 65.0,
    "GK-RM-DISC": 28.0,
    "GK-RM-PADS": 12.0,
    "GK-RM-CABLE": 15.0,
    "GK-RM-MASTER": 38.0,
    "GK-ENGINE": 850.0,
}


def log(msg):
    print("MARK %s" % msg)


def ensure_price(item_code, price_list, rate, is_selling):
    if frappe.db.exists("Item Price", {"item_code": item_code, "price_list": price_list}):
        return False
    frappe.get_doc({
        "doctype": "Item Price",
        "item_code": item_code,
        "uom": "Nos",
        "price_list": price_list,
        "price_list_rate": rate,
        "currency": "MYR",
        "selling": 1 if is_selling else 0,
        "buying": 0 if is_selling else 1,
    }).insert(ignore_permissions=True)
    return True


def main():
    frappe.init(site=SITE, sites_path=".")
    frappe.connect()
    frappe.set_user("Administrator")

    # Make the engine sellable so its selling price is usable as a spare part.
    engine = frappe.get_doc("Item", "GK-ENGINE")
    if not engine.is_sales_item:
        engine.is_sales_item = 1
        engine.save(ignore_permissions=True)
        log("GK-ENGINE marked sellable")

    created_s, created_b = 0, 0
    for code, rate in SELLING_PRICES.items():
        if ensure_price(code, SELLING_PL, rate, is_selling=True):
            created_s += 1
    for code, rate in BUYING_PRICES.items():
        if ensure_price(code, BUYING_PL, rate, is_selling=False):
            created_b += 1
    frappe.db.commit()

    summary = {
        "selling_prices": len(SELLING_PRICES),
        "buying_prices": len(BUYING_PRICES),
        "created_selling": created_s,
        "created_buying": created_b,
        "total_item_prices": frappe.db.count("Item Price", {"item_code": ["like", "GK-%"]}),
    }
    print("SUMMARY " + json.dumps(summary, default=str))
    print("DONE")


if __name__ == "__main__":
    main()
