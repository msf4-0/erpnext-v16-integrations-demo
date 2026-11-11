#!/usr/bin/env python3
"""Create a demo end-user Role + login User for comp_demo.

WHY: the stack only shipped the `Administrator` login (System Manager). That is
fine for a build agent but wrong for "ready for user use" - a real user must not
log in as Administrator, and there was no non-admin role with the permissions a
warehouse / sales / manufacturing operator needs to run the demo.

This script (idempotent) creates:

  1. Role `Demo User` (desk_access=1) with an explicit read/write/create/submit
     permission set across every doctype the demo exercises - stock, sales,
     manufacturing, barcode printing, e-invoicing and Shopify - plus read-only
     access to the master data those documents depend on.
  2. User `demo@comp_demo.local` / password `demo`, assigned the `Demo User`
     role (plus Employee Self Service so the account is a normal desk login).

Run inside the bench container:

    cd /home/frappe/frappe-bench && SITE_NAME=frontend ./env/bin/python \
        /tmp/scripts/create-demo-user.py

The password is a demo default - tell the operator to change it before any
shared use. Nothing here grants System Manager, so the account cannot reach
Setup or destructive financial actions.
"""
import os

import frappe

SITE = os.environ.get("SITE_NAME", "frontend")
os.chdir("/home/frappe/frappe-bench/sites")
frappe.init(site=SITE, sites_path=".")
frappe.connect()
frappe.set_user("Administrator")

ROLE = "Demo User"
EMAIL = "demo@comp_demo.local"
PASSWORD = "demo"

# full transaction access: read/write/create/submit/cancel/amend/print/export/report
# (dict literals because `import` is a reserved word and can't be a kwarg)
FULL = {
    "read": 1, "write": 1, "create": 1, "delete": 0, "submit": 1, "cancel": 1,
    "amend": 1, "report": 1, "export": 1, "import": 0, "print": 1, "email": 1,
    "share": 1, "select": 1, "setup": 0, "if_owner": 0, "permlevel": 0,
}

# read-only master data: read/export/print/report
READ = {
    "read": 1, "write": 0, "create": 0, "delete": 0, "submit": 0, "cancel": 0,
    "amend": 0, "report": 1, "export": 1, "import": 0, "print": 1, "email": 0,
    "share": 0, "select": 1, "setup": 0, "if_owner": 0, "permlevel": 0,
}

# Doctypes the demo exercises, grouped by feature.
TRANSACTIONAL = [
    # stock / inventory
    "Item", "Item Barcode", "Item Price", "Stock Entry", "Stock Reconciliation",
    "Stock Ledger Entry", "Bin", "Delivery Note", "Sales Invoice", "Sales Order",
    # manufacturing
    "Work Order", "Job Card", "Operation", "Workstation", "BOM",
    "Virtual Work Order",
    # barcode + e-invoicing + shopify
    "Barcode Printing", "E Invoice Import", "Shopify Settings", "Shopify Log",
    # purchasing (inbound demo flow)
    "Purchase Order", "Purchase Receipt", "Purchase Invoice",
]

MASTERS = [
    "Company", "Warehouse", "Item Group", "UOM", "Currency", "Price List",
    "Customer", "Supplier", "Address", "Contact", "Terms and Conditions",
    "Sales Taxes and Charges Template", "Purchase Taxes and Charges Template",
    "Item Price", "Serial No", "Batch", "Customer Group", "Supplier Group",
]


def upsert_role():
    if frappe.db.exists("Role", ROLE):
        role = frappe.get_doc("Role", ROLE)
    else:
        role = frappe.get_doc({"doctype": "Role", "role_name": ROLE, "desk_access": 1})
        role.insert(ignore_permissions=True)

    # Rebuild the permission table deterministically (idempotent across runs).
    role.set("permissions", [])
    for dt in TRANSACTIONAL:
        row = dict(FULL)
        row["doctype"] = dt
        role.append("permissions", row)
    for dt in MASTERS:
        row = dict(READ)
        row["doctype"] = dt
        role.append("permissions", row)

    role.desk_access = 1
    role.save(ignore_permissions=True)
    frappe.db.commit()
    print(f"[demo-user] role '{ROLE}' ready: "
          f"{len(TRANSACTIONAL)} full + {len(MASTERS)} read-only doctypes")


def upsert_user():
    if frappe.db.exists("User", EMAIL):
        user = frappe.get_doc("User", EMAIL)
        user.enabled = 1
    else:
        user = frappe.get_doc({
            "doctype": "User",
            "email": EMAIL,
            "first_name": "Demo",
            "last_name": "User",
            "user_type": "System User",
            "send_welcome_email": 0,
            "enabled": 1,
            "new_password": PASSWORD,
        })
        user.insert(ignore_permissions=True)

    # Ensure the role is attached (roles is a child table keyed by role).
    existing_roles = {r.role for r in user.get("roles", [])}
    for r in (ROLE, "Employee Self Service"):
        if r not in existing_roles:
            user.append("roles", {"role": r})
    user.save(ignore_permissions=True)

    # The password is set once at creation via `new_password` (above). We do NOT
    # reset it on re-runs, so an operator who changes the demo password keeps it.
    frappe.db.commit()
    print(f"[demo-user] user '{EMAIL}' ready, roles={[r.role for r in user.roles]}")


if __name__ == "__main__":
    upsert_role()
    upsert_user()
    print("[demo-user] done - login with demo@comp_demo.local / demo")
