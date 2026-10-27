#!/usr/bin/env python3
"""Give the guest-checkout customers real names (data tidy, idempotent).

The Shopify order/customer sync used to name every guest checkout
"Shopify Customer" (and "Shopify Customer None" once a null slipped into the
f-string), so the site ended up with 250 rows that look like one customer.
The code is fixed; this renames the rows that were already created.

    SITE_NAME=frontend ./env/bin/python /tmp/scripts/fix-shopify-customers.py [--dry-run]
"""
import os
import re
import sys

import frappe

SITE = os.environ.get("SITE_NAME", "frontend")
DRY = "--dry-run" in sys.argv
os.chdir("/home/frappe/frappe-bench/sites")
frappe.init(site=SITE, sites_path=".")
frappe.connect()
frappe.set_user("Administrator")

JUNK = re.compile(r"^(shopify customer( none)?)$", re.IGNORECASE)

rows = frappe.get_all(
    "Customer",
    fields=["name", "customer_name", "shopify_customer_id", "email_id"],
    limit_page_length=0,
)
junk = [r for r in rows if r.customer_name and JUNK.match(r.customer_name.strip())]
print("CLEANUP customers=%d junk=%d dry_run=%s" % (len(rows), len(junk), DRY))

renamed = 0
for row in junk:
    suffix = str(row.shopify_customer_id or "")[-4:] or "guest"
    new_name = row.email_id or ("Shopify Guest %s" % suffix)
    if new_name.strip().lower() == (row.customer_name or "").strip().lower():
        continue
    if not DRY:
        frappe.db.set_value("Customer", row.name, "customer_name", new_name, update_modified=False)
    renamed += 1
    if renamed <= 5:
        print("CLEANUP %s: %r -> %r" % (row.name, row.customer_name, new_name))

if not DRY:
    frappe.db.commit()
print("CLEANUP renamed=%d" % renamed)
frappe.destroy()
