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
import re
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
# Prefer the "Products" group the rest of the repo standardises on
# (bootstrap_masters.py, seed_planner_demo.py, retrieve_product.py). The old
# "first non-group" lookup returned whatever the DB happened to hand back first,
# e.g. "Finished Goods", which put raw materials in the wrong group.
ITEM_GROUP = (
    frappe.db.get_value("Item Group", "Products", "name")
    or frappe.db.get_value("Item Group", {"is_group": 0}, "name")
    or "Products"
)
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
    # Every go-kart part is serial-tracked.  The restored demo database already
    # carries serial rows for these codes (GKRT-001-####, WHL-001-####, ...), and
    # a Serial No whose Item is not serial-tracked is a broken reference in
    # ERPNext, so the flag has to be on for all of them.
    ("GO-KART", "Go-Kart (assembled)", 4500.0, None, True,
     "Assembled go-kart - the finished good this demo builds."),
    ("FRM-001", "Frame", 1800.0, 1400.0, True,
     "Go-kart frame (go-kart demo item). Serial-tracked."),
    ("WHL-001", "Wheel", 220.0, 150.0, True, "Go-kart wheel - four per kart."),
    ("STR-001", "Steering Wheel", 310.0, 210.0, True, "Go-kart steering wheel - one per kart."),
    ("SEAT-001", "Seat", 260.0, 180.0, True, "Go-kart seat - one per kart."),
]


def _may_track_serials(code: str) -> bool:
    """Can this item be switched to serial-tracked without breaking accounting?

    ERPNext refuses to change `has_serial_no` once a submitted Stock Entry
    points at the item.  Asking first is cleaner than triggering that error and
    rolling back: a demo seeder must never out-vote posted stock transactions.
    """
    if frappe.db.get_value("Item", code, "has_serial_no"):
        return True  # already on - nothing to change
    return not frappe.db.exists("Stock Ledger Entry", {"item_code": code})


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
        # No `company` here on purpose: Item has no company field, so setting one
        # never persists and every run would look "changed" (the seeder then
        # rewrites all five items on each converge and never reports "current").
        # Company-scoped defaults belong on Item Default, not Item.
    }
    if serial:
        if _may_track_serials(code):
            values["serial_no_series"] = f"{code}-.####"
            values["has_batch_no"] = 0
        else:
            # Leave the flag exactly as posted stock transactions expect it.
            values.pop("has_serial_no", None)
            note("skipped", f"Item {code} stays non-serial (posted stock entries pin the flag)")
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
# keep the Serial No naming-series counter in step with the serials that exist
# ---------------------------------------------------------------------------
# Creating Serial No rows with frappe.get_doc().insert() stores the name as-is;
# it does NOT advance tabSeries, which is what frappe.model.naming.make_autoname
# reads.  So after inserting FRM-001-0017..0068 directly, the counter still said
# 16 and the next auto-generated serial was FRM-001-0017 again - the
# "naming series conflict occurred while creating serial numbers" error when
# submitting a Purchase Receipt.  Syncing the counter here makes fresh clones
# correct and makes this script idempotent.
SERIAL_ITEM = "FRM-001"
try:
    series = frappe.db.get_value("Item", SERIAL_ITEM, "serial_no_series") or "FRM-001-.####"
    prefix = series.rsplit(".", 1)[0]
    used = [
        int(m.group(1))
        for row in frappe.get_all(
            "Serial No", filters={"item_code": SERIAL_ITEM}, fields=["serial_no"], limit=100000
        )
        if (m := re.search(r"(\d+)$", row.serial_no or ""))
    ]
    highest = max(used) if used else 0
    existing = frappe.db.sql("select current from tabSeries where name=%s", prefix)
    current = existing[0][0] if existing else 0
    if highest > current:
        if existing:
            frappe.db.sql("update tabSeries set current=%s where name=%s", (highest, prefix))
        else:
            frappe.db.sql("insert into tabSeries (name, current) values (%s, %s)", (prefix, highest))
        note("updated", f"Sequence {prefix} -> {highest} (next serial {prefix}{highest + 1:04d})")
    else:
        note("skipped", f"Sequence {prefix} already at {current}")
except Exception as exc:  # noqa: BLE001
    note("errors", f"Sequence sync: {type(exc).__name__}: {exc}")
    frappe.db.rollback()

# ---------------------------------------------------------------------------
# adopt the serial numbers left behind by the retired barcode go-kart
# ---------------------------------------------------------------------------
# The old barcode demo serialised six items.  Three of those codes no longer
# exist, so their Serial No rows point at nothing.  Where a retired code has an
# exact equivalent in this dataset the serials are re-pointed instead of being
# deleted: the serial *string* is kept (it may be printed on a label / QR code),
# only the owning Item changes.
LEGACY_SERIAL_REMAP = {"GKRT-001": "GO-KART", "SET-001": "SEAT-001"}
# HST-001 ("Handling") has no counterpart in this four-part recipe, so its
# serials are deliberately left alone and reported - deleting demo records is a
# decision for the operator, not for an idempotent seeder.
UNMAPPED_SERIAL_HINT = {"HST-001": "no matching item in this dataset"}
try:
    for legacy_code, target in LEGACY_SERIAL_REMAP.items():
        rows = frappe.get_all("Serial No", filters={"item_code": legacy_code}, fields=["name"])
        for row in rows:
            frappe.db.set_value("Serial No", row.name, "item_code", target, update_modified=False)
        note("updated" if rows else "skipped",
             f"Serial No {legacy_code}-* re-pointed to {target} ({len(rows)} rows)")
    for legacy_code, why in UNMAPPED_SERIAL_HINT.items():
        left = frappe.db.count("Serial No", {"item_code": legacy_code})
        if left:
            note("skipped", f"Serial No {legacy_code}-* left as-is ({left} rows, {why})")
except Exception as exc:  # noqa: BLE001
    note("errors", f"Serial No re-point: {type(exc).__name__}: {exc}")
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
                # "Price List" reads each component's Standard Buying rate, which
                # this script always creates. "Valuation Rate" reads the stock
                # valuation instead, and on a fresh site there is no stock - the
                # BOM then reports a total cost of 0.00, which is what the demo
                # used to show. Every other BOM in this repo uses "Price List".
                "rm_cost_as_per": "Price List",
                "buying_price_list": BUYING,
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
