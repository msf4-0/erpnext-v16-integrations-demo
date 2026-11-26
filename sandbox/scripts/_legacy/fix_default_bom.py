#!/usr/bin/env python3
"""Mark GKRT-001 BOM as default and point the Item at it (fixes SO->WO manufacture).

Run inside the bench container:
    cd /home/frappe/frappe-bench && SITE_NAME=frontend \
        ./env/bin/python /tmp/fix_default_bom.py
"""
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")


def main():
    frappe.init(site=SITE, sites_path=".")
    frappe.connect()
    frappe.set_user("Administrator")

    item = "GKRT-001"
    bom = frappe.db.get_value("BOM", {"item": item, "docstatus": 1}, "name")
    if not bom:
        raise SystemExit("ERROR: no submitted BOM for %s" % item)

    print("before: bom=%s is_default=%s | item default_bom=%s" % (
        bom,
        frappe.db.get_value("BOM", bom, "is_default"),
        frappe.db.get_value("Item", item, "default_bom"),
    ))

    # Ensure only this BOM is default for the item.
    frappe.db.sql("UPDATE `tabBOM` SET is_default=0 WHERE item=%s AND name!=%s", (item, bom))
    frappe.db.set_value("BOM", bom, "is_default", 1)
    frappe.db.set_value("Item", item, "default_bom", bom)
    frappe.db.commit()

    print("after:  bom=%s is_default=%s | item default_bom=%s" % (
        bom,
        frappe.db.get_value("BOM", bom, "is_default"),
        frappe.db.get_value("Item", item, "default_bom"),
    ))
    print("DONE")


if __name__ == "__main__":
    main()
