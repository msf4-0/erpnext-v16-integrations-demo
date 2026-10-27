#!/usr/bin/env python3
"""Print the current demo state in one shot (used while babysitting a build).

    cd /home/frappe/frappe-bench && SITE_NAME=frontend ./env/bin/python \
        /tmp/scripts/probe-state.py

Everything is prefixed so a human or the host wrapper can grep it.
"""
import json
import os
import sys

import frappe

SITE = os.environ.get("SITE_NAME", "frontend")
os.chdir("/home/frappe/frappe-bench/sites")
frappe.init(site=SITE, sites_path=".")
frappe.connect()
frappe.set_user("Administrator")


def count(doctype, filters=None):
    try:
        return frappe.db.count(doctype, filters or {})
    except Exception:
        return -1


print("PROBE site=%s db=%s" % (frappe.local.site, frappe.conf.db_name))
print("PROBE apps=%s" % ",".join(r["app_name"] for r in frappe.get_all("Installed Application", fields=["app_name"])))

for doctype in (
    "Company",
    "Item",
    "Item Barcode",
    "Customer",
    "Supplier",
    "Supplier Group",
    "Stock Entry Type",
    "Client Script",
    "Barcode Printing",
    "Work Order",
    "Job Card",
    "Workstation",
    "BOM",
    "Delivery Note",
    "Stock Entry",
    "Sales Invoice",
    "Sales Order",
    "Webhook",
    "Shopify Access",
    "Virtual Work Order",
    "Error Log",
):
    print("PROBE count %-22s %s" % (doctype, count(doctype)))

enabled_scripts = frappe.get_all("Client Script", filters={"enabled": 1}, pluck="name")
print("PROBE client_scripts_enabled=%d" % len(enabled_scripts))

try:
    access = frappe.get_all("Shopify Access", fields=["name", "shopify_url", "updated_version"])
    print("PROBE shopify_access=%s" % json.dumps(access))
except Exception as exc:
    print("PROBE shopify_access ERR %s" % exc)

try:
    from shopify.auth import token_status

    print("PROBE token=%s" % json.dumps(token_status(), sort_keys=True))
except Exception as exc:
    print("PROBE token ERR %s: %s" % (type(exc).__name__, exc))

if frappe.db.exists("DocType", "Virtual Work Order"):
    print("PROBE vwo doctype=present")
else:
    print("PROBE vwo doctype=MISSING")

for row in frappe.get_all(
    "Work Order",
    fields=["name", "production_item", "planned_start_date", "status"],
    order_by="planned_start_date asc",
    limit_page_length=20,
):
    print(
        "PROBE wo %-22s %-16s %s %s"
        % (row.name, row.production_item, row.planned_start_date, row.status)
    )

try:
    import requests

    resp = requests.get("http://localhost:8000/api/method/ping", headers={"Host": SITE}, timeout=15)
    print("PROBE ping=%s %s" % (resp.status_code, (resp.text or "")[:80]))
except Exception as exc:
    print("PROBE ping=ERR %s" % exc)

rows = frappe.get_all(
    "Error Log",
    fields=["method", "error", "creation"],
    order_by="creation desc",
    limit_page_length=8,
)
for row in rows:
    print(
        "PROBE errorlog %s | %s | %s"
        % (row.creation, (row.method or "")[:38], (row.error or "").replace("\n", " ")[:180])
    )

frappe.db.commit()
frappe.destroy()
