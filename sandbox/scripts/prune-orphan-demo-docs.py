#!/usr/bin/env python3
"""Find (and optionally remove) demo documents whose item lines point at Items
that no longer exist.

Why this exists
---------------
Retiring a demo item without checking its history leaves rows behind that
reference an Item nobody can look up.  Those rows are not cosmetic:

  * opening the document shows a blank/`undefined` item row;
  * Sales Order > Create > Request for Raw Material opens an EMPTY dialog,
    because ERPNext guards that path with `if (!r.message)` and an empty
    JavaScript array is *truthy* - so instead of the "No Items with Bill of
    Materials." message you get a dialog with no rows;
  * reports and stock queries silently skip the row.

The item-side fix (never force-delete a referenced Item) lives in
`barcode_shrdc/demo.py`.  This script cleans up the damage already done.

Safety
------
* Dry run by default. Nothing is cancelled or deleted without `--apply`.
* A document is skipped (and reported) when another document points at it,
  so removing it cannot orphan a delivery note, work order, invoice or
  payment.
* Only Sales Order and Quotation are pruned by default: they are the two
  doctypes that produce the empty-dialog symptom.  Use `--doctypes` to widen.
* The script never touches Items, stock or accounting ledgers.

Usage (inside the bench container)
---------------------------------
    cd /home/frappe/frappe-bench && SITE_NAME=frontend \
        ./env/bin/python /tmp/scripts/prune-orphan-demo-docs.py

    # then, once the list looks right:
    ... prune-orphan-demo-docs.py --apply
"""
from __future__ import annotations

import argparse
import os
import sys

import frappe

SITE = os.environ.get("SITE_NAME", "frontend")
# Order matters: a Material Request raised from a Sales Order keeps a link row
# back to it (even when the MR is cancelled), so MRs must go first or the SO
# delete fails with LinkExistsError.
DEFAULT_DOCTYPES = ("Material Request", "Sales Order", "Quotation")
# child doctype -> field holding the item code
ITEM_TABLES = {
    "Sales Order": "Sales Order Item",
    "Quotation": "Quotation Item",
    "Delivery Note": "Delivery Note Item",
    "Purchase Order": "Purchase Order Item",
    "Material Request": "Material Request Item",
    "Stock Entry": "Stock Entry Detail",
}


def dangling_items(item_table: str) -> set[str]:
    codes = {
        r["item_code"]
        for r in frappe.get_all(item_table, fields=["item_code"], limit=100000)
        if r["item_code"]
    }
    return {c for c in codes if not frappe.db.exists("Item", c)}


def linked_documents(doctype: str, name: str) -> list[tuple[str, str]]:
    """Other documents that reference `name` (would break if we delete it)."""
    probes = {
        "Sales Order": [
            ("Delivery Note Item", "against_sales_order"),
            ("Work Order", "sales_order"),
            ("Sales Invoice Item", "sales_order"),
            ("Sales Order", "amended_from"),
            # A Material Request raised from the SO keeps a row pointing back at
            # it.  Cancelled MRs still block deletion, so they have to be pruned
            # first: run with --doctypes "Material Request,Sales Order,Quotation".
            ("Material Request Item", "sales_order"),
        ],
        "Quotation": [("Sales Order Item", "prevdoc_docname"), ("Quotation", "amended_from")],
    }
    found = []
    for dt, field in probes.get(doctype, []):
        if not frappe.db.exists("DocType", dt):
            continue
        for row in frappe.get_all(dt, filters={field: name}, fields=["name"], limit=5):
            found.append((dt, row["name"]))
    return found


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="actually cancel/delete (default: dry run)")
    ap.add_argument("--doctypes", default=",".join(DEFAULT_DOCTYPES),
                    help=f"comma separated (default: {','.join(DEFAULT_DOCTYPES)})")
    args = ap.parse_args()

    # frappe resolves its log/config paths from the working directory, so cd into
    # `sites` first (same pattern as seed-gokart-demo.py).  Without this you get
    # FileNotFoundError: <site>/logs/database.log before DB access even starts.
    sites = os.environ.get("SITES_PATH", "/home/frappe/frappe-bench/sites")
    os.chdir(sites)
    frappe.init(site=SITE, sites_path=".")
    frappe.connect()
    frappe.set_user("Administrator")

    targets = [d.strip() for d in args.doctypes.split(",") if d.strip()]
    mode = "APPLY" if args.apply else "DRY RUN"
    print(f"== prune orphan demo documents ({mode}) site={SITE} ==")

    removed = skipped = 0
    for doctype in targets:
        table = ITEM_TABLES.get(doctype)
        if not table:
            print(f"  SKIP  {doctype}: no item table mapping")
            continue
        gone = dangling_items(table)
        if not gone:
            print(f"  OK    {doctype}: no dangling item references")
            continue

        parents = sorted({
            r["parent"]
            for r in frappe.get_all(table, fields=["parent", "item_code"], limit=100000)
            if r["item_code"] in gone
        })
        for name in parents:
            doc_hdr = frappe.db.get_value(doctype, name, ["docstatus"], as_dict=True)
            if not doc_hdr:
                continue
            links = linked_documents(doctype, name)
            if links:
                print(f"  KEEP  {doctype} {name}: referenced by {links}")
                skipped += 1
                continue
            print(f"  {'DEL ' if args.apply else 'WOULD'} {doctype} {name} "
                  f"(docstatus={doc_hdr.docstatus})")
            if not args.apply:
                continue
            try:
                doc = frappe.get_doc(doctype, name)
                if doc.docstatus == 1:
                    doc.cancel()
                frappe.delete_doc(doctype, name, force=0, ignore_permissions=True)
                # Commit per document: a single failure further down the list must
                # not roll back the deletions that already succeeded.
                frappe.db.commit()
                removed += 1
            except Exception as exc:  # noqa: BLE001
                print(f"        KEPT {type(exc).__name__}: {str(exc)[:160]}")
                skipped += 1
                frappe.db.rollback()

    if args.apply:
        frappe.db.commit()
    print(f"== {'removed' if args.apply else 'would remove'}: "
          f"{removed if args.apply else 'see above'} | kept: {skipped} ==")
    frappe.destroy()
    return 0


if __name__ == "__main__":
    sys.exit(main())
