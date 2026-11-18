#!/usr/bin/env python3
"""Delete leftover go-kart demo rows directly (custom app blocks cancel()).

The `item_tracking` app ships a broken `Stock Entry Tracked Item` child whose
module cannot be imported, so `StockEntry.cancel()` raises. Normal cancel/delete
already removed all Items + most docs; this removes the residual rows via SQL.

Run inside the bench container:
    cd /home/frappe/frappe-bench && SITE_NAME=frontend \
        ./env/bin/python /tmp/cleanup_go_kart_leftovers.py
"""
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")


def sql(qry, *args):
    return frappe.db.sql(qry, args)


def inlist(names):
    if not names:
        return "('')"
    return "(" + ",".join("'%s'" % n for n in names) + ")"


def names_of(qry, *args):
    return [r[0] for r in sql(qry, *args)]


def delete_children_then_parent(parent_table, child_tables, parent_names):
    plist = inlist(parent_names)
    for ct in child_tables:
        try:
            sql("DELETE FROM `tab%s` WHERE parent IN %s" % (ct, plist))
        except Exception as e:  # noqa: BLE001
            print("  skip child %s: %s" % (ct, str(e)[:120]))
    sql("DELETE FROM `tab%s` WHERE name IN %s" % (parent_table, plist))
    print("  deleted parents from %s (%d parents)" % (parent_table, len(parent_names)))


def main():
    frappe.init(site=SITE, sites_path=".")
    frappe.connect()
    frappe.set_user("Administrator")

    # Work orders (production_item is a stored link value, still GK-* text).
    wos = names_of("SELECT name FROM `tabWork Order` WHERE production_item LIKE 'GK-%%'")
    jcs = names_of("SELECT name FROM `tabJob Card` WHERE work_order IN %s" % inlist(wos))
    delete_children_then_parent("Job Card", ["Job Card Time Log", "Job Card Item"], jcs)
    delete_children_then_parent("Work Order", ["Work Order Item", "Work Order Operation"], wos)

    # Stock entries (items still hold GK-* item_code).
    ses = names_of("SELECT DISTINCT parent FROM `tabStock Entry Detail` WHERE item_code LIKE 'GK-%%'")
    delete_children_then_parent("Stock Entry", ["Stock Entry Detail", "Stock Entry Tracked Item"], ses)

    prs = names_of("SELECT DISTINCT parent FROM `tabPurchase Receipt Item` WHERE item_code LIKE 'GK-%%'")
    delete_children_then_parent("Purchase Receipt", ["Purchase Receipt Item", "Purchase Receipt Stock Detail"], prs)

    mrs = names_of("SELECT DISTINCT parent FROM `tabMaterial Request Item` WHERE item_code LIKE 'GK-%%'")
    delete_children_then_parent("Material Request", ["Material Request Item"], mrs)

    sos = names_of("SELECT DISTINCT parent FROM `tabSales Order Item` WHERE item_code LIKE 'GK-%%'")
    delete_children_then_parent("Sales Order", ["Sales Order Item", "Packed Item"], sos)

    boms = names_of("SELECT name FROM `tabBOM` WHERE item LIKE 'GK-%%'")
    delete_children_then_parent("BOM", ["BOM Item", "BOM Operation", "BOM Scrap Item"], boms)

    # Stock ledger + GL entries.
    sql("DELETE FROM `tabStock Ledger Entry` WHERE item_code LIKE 'GK-%%'")
    print("  deleted Stock Ledger Entry rows (GK-%)")
    vouchers = set(ses) | set(prs) | set(sos)
    sql("DELETE FROM `tabGL Entry` WHERE voucher_no IN %s" % inlist(sorted(vouchers)))
    print("  deleted GL Entry rows for %d vouchers" % len(vouchers))

    # Orphaned go-kart demo operations (description says go-kart).
    ops = names_of("SELECT name FROM `tabOperation` WHERE LOWER(description) LIKE '%%go-kart%%'")
    for op in ops:
        refs = sql("SELECT COUNT(*) FROM `tabBOM Operation` WHERE operation=%s", op)[0][0]
        refs += sql("SELECT COUNT(*) FROM `tabWork Order Operation` WHERE operation=%s", op)[0][0]
        if refs == 0:
            sql("DELETE FROM `tabOperation` WHERE name=%s", op)
            print("  deleted orphaned Operation %s" % op)
        else:
            print("  kept Operation %s (refs=%d)" % (op, refs))

    frappe.db.commit()

    # Final report.
    left = {}
    for label, qry in [
        ("Item", "SELECT COUNT(*) FROM `tabItem` WHERE item_code LIKE 'GK-%%'"),
        ("BOM", "SELECT COUNT(*) FROM `tabBOM` WHERE item LIKE 'GK-%%'"),
        ("Work Order", "SELECT COUNT(*) FROM `tabWork Order` WHERE production_item LIKE 'GK-%%'"),
        ("Job Card", "SELECT COUNT(*) FROM `tabJob Card` WHERE work_order LIKE 'MFG-WO%%'"),
        ("Stock Entry Detail", "SELECT COUNT(*) FROM `tabStock Entry Detail` WHERE item_code LIKE 'GK-%%'"),
        ("Purchase Receipt Item", "SELECT COUNT(*) FROM `tabPurchase Receipt Item` WHERE item_code LIKE 'GK-%%'"),
        ("Material Request Item", "SELECT COUNT(*) FROM `tabMaterial Request Item` WHERE item_code LIKE 'GK-%%'"),
        ("Sales Order Item", "SELECT COUNT(*) FROM `tabSales Order Item` WHERE item_code LIKE 'GK-%%'"),
        ("Item Price", "SELECT COUNT(*) FROM `tabItem Price` WHERE item_code LIKE 'GK-%%'"),
        ("Stock Ledger Entry", "SELECT COUNT(*) FROM `tabStock Ledger Entry` WHERE item_code LIKE 'GK-%%'"),
        ("Bin", "SELECT COUNT(*) FROM `tabBin` WHERE item_code LIKE 'GK-%%'"),
    ]:
        left[label] = sql(qry)[0][0]
    print("REMAINING: %s" % left)
    print("DONE")


if __name__ == "__main__":
    main()
