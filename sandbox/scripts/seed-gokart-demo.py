#!/usr/bin/env python3
"""Seed the SIMPLE go-kart demo dataset (replaces the old production-style demo).

Run inside the bench container:

    cd /home/frappe/frappe-bench && SITE_NAME=frontend ./env/bin/python \
        /tmp/scripts/seed-gokart-demo.py

What it creates (idempotent - safe to run on every build):

  * Items: GO-KART (assembly), FRM-001 Frame (serial-tracked), WHL-001 Wheel,
    STR-001 Steering Wheel, SEAT-001 Seat
  * Item Prices: Standard Selling for all five, Standard Buying for the parts
  * BOM: GO-KART = 1 Frame + 4 Wheels + 1 Steering Wheel + 1 Seat
  * Serial Numbers FRM-001-0001 .. FRM-001-0068 attached to FRM-001, so the
    serial numbers that already existed in older dumps are carried forward
    instead of being orphaned (they used to point at an Item that was missing).

Everything is created against the demo Company (SHRDC by default) and the
standard "Products" item group, so it works on a freshly provisioned site with
no demo data at all.
"""
from __future__ import annotations

import os
import sys

import frappe

SITE = os.environ.get("SITE_NAME", "frontend")
COMPANY = os.environ.get("DEMO_COMPANY", "SHRDC")
FRAME_SERIALS = int(os.environ.get("FRAME_SERIALS", "68"))

os.chdir("/home/frappe/frappe-bench/sites")
frappe.init(site=SITE, sites_path=".")
frappe.connect()
frappe.set_user("Administrator")

log: dict[str, list[str]] = {"created": [], "updated": [], "skipped": [], "errors": []}


def note(kind: str, msg: str) -> None:
    log[kind].append(msg)


# ---------------------------------------------------------------------------
# reference data the recipe depends on
# ---------------------------------------------------------------------------
def company() -> str:
    name = frappe.db.get_value("Company", {"company_name": COMPANY}, "name") or frappe.db.get_value(
        "Company", {}, "name"
    )
    if not name:
        raise RuntimeError("no Company on this site - run the master bootstrap first")
    return name


COMP = company()
CURRENCY = frappe.db.get_value("Company", COMP, "default_currency") or "MYR"
ITEM_GROUP = frappe.db.get_value("Item Group", {"is_group": 0}, "name") or "Products"
UOM = "Nos"
SELLING = "Standard Selling"
BUYING = "Standard Buying"

for pl in (SELLING, BUYING):
    if not frappe.db.exists("Price List", pl):
        doc = frappe.get_doc({"doctype": "Price List", "price_list_name": pl, "currency": CURRENCY,
                              "selling": 1 if pl == SELLING else 0, "buying": 0 if pl == SELLING else 1})
        doc.insert(ignore_permissions=True)
        note("created", f"Price List {pl}")

# ---------------------------------------------------------------------------
# items
# ---------------------------------------------------------------------------
ITEMS = [
    # code, name, selling rate, buying rate, serial-tracked, description
    ("GO-KART", "Go-Kart (assembled)", 4500.0, None, False,
     "Assembled go-kart - the finished good this demo builds."),
    ("FRM-001", "Frame", 1800.0, 1400.0, True,
     "Go-kart frame (go-kart demo item). Serial-tracked."),
    ("WHL-001", "Wheel", 220.0, 150.0, False, "Go-kart wheel - four per kart."),
    ("STR-001", "Steering Wheel", 310.0, 210.0, False, "Go-kart steering wheel - one per kart."),
    ("SEAT-001", "Seat", 260.0, 180.0, False, "Go-kart seat - one per kart."),
]


def ensure_item(code, name, selling, buying, serial, description) -> None:
    values = {
        "item_code": code,
        "item_name": name,
        "description": description,
        "item_group": ITEM_GROUP,
        "stock_uom": UOM,
        "is_stock_item": 1,
        "is_sales_item": 1,
        "is_purchase_item": 1,
        "include_item_in_manufacturing": 1,
        "has_serial_no": 1 if serial else 0,
        "company": COMP,
    }
    if serial:
        values["serial_no_series"] = f"{code}-.####"
        values["has_batch_no"] = 0
    if frappe.db.exists("Item", code):
        doc = frappe.get_doc("Item", code)
        changed = False
        for field, value in values.items():
            if field in ("item_code",):
                continue
            if doc.get(field) != value and value is not None:
                doc.set(field, value)
                changed = True
        if changed:
            doc.save(ignore_permissions=True)
            note("updated", f"Item {code}")
        else:
            note("skipped", f"Item {code} already correct")
    else:
        doc = frappe.get_doc({"doctype": "Item", **values})
        doc.insert(ignore_permissions=True)
        note("created", f"Item {code}")

    for price_list, rate in ((SELLING, selling), (BUYING, buying)):
        if rate is None:
            continue
        filters = {"item_code": code, "price_list": price_list, "currency": CURRENCY}
        existing = frappe.db.get_value("Item Price", filters, "name")
        if existing:
            frappe.db.set_value("Item Price", existing, "price_list_rate", rate)
        else:
            frappe.get_doc(
                {"doctype": "Item Price", "item_code": code, "price_list": price_list,
                 "price_list_rate": rate, "currency": CURRENCY,
                 "selling": 1 if price_list == SELLING else 0,
                 "buying": 0 if price_list == SELLING else 1, "uom": UOM}
            ).insert(ignore_permissions=True)
            note("created", f"Item Price {code} @ {price_list} = {rate}")


for row in ITEMS:
    try:
        ensure_item(*row)
    except Exception as exc:  # noqa: BLE001
        note("errors", f"Item {row[0]}: {type(exc).__name__}: {exc}")
        frappe.db.rollback()

# ---------------------------------------------------------------------------
# serial numbers for the frame, reusing the FRM-001-#### series
# ---------------------------------------------------------------------------
try:
    made = 0
    for i in range(1, FRAME_SERIALS + 1):
        serial = f"FRM-001-{i:04d}"
        if frappe.db.exists("Serial No", serial):
            continue
        frappe.get_doc(
            {"doctype": "Serial No", "serial_no": serial, "item_code": "FRM-001",
             "status": "Active", "company": COMP, "description": "Frame (go-kart demo item)"}
        ).insert(ignore_permissions=True)
        made += 1
    note("created" if made else "skipped", f"Serial No FRM-001-0001..{FRAME_SERIALS:04d} (+{made} new)")
except Exception as exc:  # noqa: BLE001
    note("errors", f"Serial No: {type(exc).__name__}: {exc}")
    frappe.db.rollback()

# ---------------------------------------------------------------------------
# BOM: one kart = 1 frame + 4 wheels + 1 steering wheel + 1 seat
# ---------------------------------------------------------------------------
BOM_ITEMS = [("FRM-001", 1), ("WHL-001", 4), ("STR-001", 1), ("SEAT-001", 1)]
try:
    existing = frappe.db.get_value(
        "BOM", {"item": "GO-KART", "docstatus": 1, "is_active": 1}, "name"
    )
    if existing:
        note("skipped", f"BOM for GO-KART already exists ({existing})")
    else:
        bom = frappe.get_doc(
            {
                "doctype": "BOM",
                "item": "GO-KART",
                "quantity": 1,
                "uom": UOM,
                "company": COMP,
                "currency": CURRENCY,
                "with_operations": 0,
                "is_active": 1,
                "is_default": 1,
                "rm_cost_as_per": "Valuation Rate",
                "items": [
                    {"item_code": code, "qty": qty, "uom": UOM, "stock_uom": UOM}
                    for code, qty in BOM_ITEMS
                ],
            }
        )
        bom.insert(ignore_permissions=True)
        bom.submit()
        note("created", f"BOM {bom.name} for GO-KART ({len(BOM_ITEMS)} components)")
except Exception as exc:  # noqa: BLE001
    note("errors", f"BOM: {type(exc).__name__}: {exc}")
    frappe.db.rollback()

frappe.db.commit()

print("\n== go-kart demo seed ==")
for kind in ("created", "updated", "skipped", "errors"):
    for msg in log[kind]:
        print(f"  {kind.upper():8} {msg}")
print(f"\nitems: {frappe.db.count('Item')}  serials(FRM-001): "
      f"{frappe.db.count('Serial No', {'item_code': 'FRM-001'})}  "
      f"boms(GO-KART): {frappe.db.count('BOM', {'item': 'GO-KART'})}")

if log["errors"]:
    sys.exit(1)
print("== go-kart demo seed: OK ==")
