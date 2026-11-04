#!/usr/bin/env python3
"""Remove ALL go-kart demo data (items + parts + every linked transaction).

    --dry-run   : report only (default)
    --commit    : cancel + delete in dependency order

Run inside the bench container:
    cd /home/frappe/frappe-bench && SITE_NAME=frontend \
        ./env/bin/python /tmp/remove_go_kart_demo.py [--commit]
"""
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")
COMMIT = "--commit" in sys.argv

CODE_PATTERNS = ["GK-%", "%kart%", "%Kart%"]
NAME_PATTERNS = ["%go kart%", "%go-kart%", "%Go-Kart%", "%kart%"]

# Child tables keyed by their item-code field -> parent doctype.
CHILD_TABLES = {
    "Sales Order Item": "Sales Order",
    "Material Request Item": "Material Request",
    "Purchase Order Item": "Purchase Order",
    "Purchase Receipt Item": "Purchase Receipt",
    "Stock Entry Detail": "Stock Entry",
    "Sales Invoice Item": "Sales Invoice",
    "Delivery Note Item": "Delivery Note",
    "Purchase Invoice Item": "Purchase Invoice",
    "Stock Reconciliation Item": "Stock Reconciliation",
    "Pick List Item": "Pick List",
    "Quotation Item": "Quotation",
    "Supplier Quotation Item": "Supplier Quotation",
    "BOM Item": "BOM",
}

# Standalone doctypes with an item-like field (no `parent` column).
STANDALONE = {
    "Website Item": "item_code",
    "Stock Ledger Entry": "item_code",
    "Bin": "item_code",
    "Item Price": "item_code",
    "Work Order": "production_item",
    "BOM": "item",
    "Item": "item_code",
}


def like_names(doctype, field, patterns):
    names = set()
    for p in patterns:
        names.update(frappe.get_all(doctype, filters={field: ["like", p]}, pluck="name", limit_page_length=100000))
    return names


def discover():
    print("=== DISCOVERY (%s) ===" % ("dry-run" if not COMMIT else "COMMIT"))

    d = {"items": set(), "boms": set(), "wos": set(), "parents": {}, "standalone": {}}

    # Items (also items whose name matches kart wording, plus barcode parents).
    d["items"] |= like_names("Item", "item_code", CODE_PATTERNS)
    d["items"] |= like_names("Item", "item_name", NAME_PATTERNS)
    d["items"] |= set(frappe.get_all("Item Barcode", filters={"barcode": ["like", "GK-%"]}, pluck="parent"))
    print("Items (%d)" % len(d["items"]))
    for it in sorted(d["items"]):
        print("  Item %s" % it)

    # BOMs
    d["boms"] |= like_names("BOM", "item", CODE_PATTERNS)
    print("BOMs (%d)" % len(d["boms"]))
    for b in sorted(d["boms"]):
        print("  BOM %s (ds=%s)" % (b, frappe.db.get_value("BOM", b, "docstatus")))

    # Work Orders
    d["wos"] |= like_names("Work Order", "production_item", CODE_PATTERNS)
    print("Work Orders (%d)" % len(d["wos"]))
    for w in sorted(d["wos"]):
        print("  WO %s (ds=%s)" % (w, frappe.db.get_value("Work Order", w, "docstatus")))

    jcs = frappe.get_all("Job Card", filters={"work_order": ["in", list(d["wos"])]}, pluck="name")
    print("Job Cards (%d)" % len(jcs))
    d["jcs"] = set(jcs)

    # Child tables -> parent docs.
    for child, parent in CHILD_TABLES.items():
        if not frappe.db.exists("DocType", child):
            continue
        rows = like_names(child, "item_code", CODE_PATTERNS)
        if not rows:
            continue
        parents = set(frappe.get_all(child, filters={"name": ["in", list(rows)]}, pluck="parent"))
        d["parents"].setdefault(parent, set()).update(parents)
        print("%s: %d rows -> %s %s" % (child, len(rows), parent, ", ".join(sorted(parents))))

    # Standalone.
    for dt, f in STANDALONE.items():
        if dt in ("Item", "BOM", "Work Order"):
            continue
        if not frappe.db.exists("DocType", dt):
            continue
        n = like_names(dt, f, CODE_PATTERNS)
        if n:
            d["standalone"][dt] = n
            print("%s: %d rows -> %s" % (dt, len(n), ", ".join(sorted(n))))

    # Product bundles + barcode printing docs.
    d["bundles"] = set(frappe.get_all("Product Bundle", filters={"name": ["in", list(d["items"])]}, pluck="name"))
    print("Product Bundles: %s" % (", ".join(sorted(d["bundles"])) or "-"))
    d["bp_docs"] = set(frappe.get_all("Barcode Generator Items", filters={"item_code": ["like", "GK-%"]}, pluck="parent"))
    print("Barcode Printing docs: %s" % (", ".join(sorted(d["bp_docs"])) or "-"))

    # Candidate operations.
    ops = like_names("Operation", "description", ["%go-kart%", "%Go-kart%", "%Go-Kart%"])
    for nm in ["Cutting", "CNC Machining", "Assembly", "Packing"]:
        if frappe.db.exists("Operation", nm):
            ops.add(nm)
    d["ops"] = ops
    print("Candidate Operations: %s" % (", ".join(sorted(ops)) or "-"))

    # Item child tables that get auto-deleted with the item.
    for dt in ["Item Price", "Item Barcode", "Item Tax", "Item Default", "Item Reorder",
               "Item Supplier", "UOM Conversion Detail"]:
        pass

    return d


def cancel_delete(doctype, names):
    for n in sorted(names):
        try:
            if not frappe.db.exists(doctype, n):
                continue
            doc = frappe.get_doc(doctype, n)
            if doc.docstatus == 1:
                doc.cancel()
            frappe.delete_doc(doctype, n, ignore_permissions=True, force=1)
            print("  removed %s %s" % (doctype, n))
        except Exception as e:  # noqa: BLE001
            print("  FAILED %s %s: %s" % (doctype, n, str(e)[:200]))
    frappe.db.commit()


def remove(d):
    print("\n=== DELETE ===")
    # 1. Transactional parents, deepest-first.
    order = [
        "Stock Entry", "Purchase Receipt", "Sales Invoice", "Delivery Note",
        "Purchase Invoice", "Stock Reconciliation", "Pick List",
        "Sales Order", "Purchase Order", "Material Request",
        "Quotation", "Supplier Quotation",
    ]
    for dt in order:
        names = d["parents"].get(dt, set())
        if names:
            print("-- %s --" % dt)
            cancel_delete(dt, names)

    # 2. Work Orders -> Job Cards.
    if d["wos"]:
        print("-- Work Order --")
        cancel_delete("Work Order", d["wos"])
    if d.get("jcs"):
        print("-- Job Card --")
        cancel_delete("Job Card", d["jcs"])

    # 3. BOMs.
    if d["boms"]:
        print("-- BOM --")
        cancel_delete("BOM", d["boms"])

    # 4. Website Items.
    for dt in ("Website Item", "Stock Ledger Entry", "Bin"):
        names = d["standalone"].get(dt, set())
        if names:
            print("-- %s --" % dt)
            cancel_delete(dt, names)

    # 5. Item Price.
    names = d["standalone"].get("Item Price", set())
    if names:
        print("-- Item Price --")
        cancel_delete("Item Price", names)

    # 6. Barcode Printing.
    if d["bp_docs"]:
        print("-- Barcode Printing --")
        cancel_delete("Barcode Printing", d["bp_docs"])

    # 7. Product Bundle.
    if d["bundles"]:
        print("-- Product Bundle --")
        cancel_delete("Product Bundle", d["bundles"])

    # 8. Items last.
    if d["items"]:
        print("-- Item --")
        cancel_delete("Item", d["items"])

    # 9. Operations only if orphaned go-kart demo ops.
    if d["ops"]:
        print("-- Operation --")
        for n in sorted(d["ops"]):
            if not frappe.db.exists("Operation", n):
                continue
            refs = frappe.db.count("BOM Operation", {"operation": n})
            desc = (frappe.db.get_value("Operation", n, "description") or "").lower()
            if refs == 0 and "go-kart" in desc:
                cancel_delete("Operation", {n})
            else:
                print("  kept Operation %s (refs=%d)" % (n, refs))


def main():
    frappe.init(site=SITE, sites_path=".")
    frappe.connect()
    frappe.set_user("Administrator")
    d = discover()
    if COMMIT:
        remove(d)
        print("\n=== AFTER ===")
        discover()
    print("DONE")


if __name__ == "__main__":
    main()
