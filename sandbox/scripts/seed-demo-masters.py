#!/usr/bin/env python3
"""Seed the demo master data that stock site provisioning left out.

Run inside the bench container:

    cd /home/frappe/frappe-bench && SITE_NAME=frontend ./env/bin/python \
        /tmp/scripts/seed-demo-masters.py

Every step is idempotent, so up.ps1 can call it on every build. It exists because
`bench new-site` + `install-app` did NOT import several standard fixtures on this
build, which silently broke real features:

  * Supplier Group          -> Customer/Supplier could not be created at all
  * Stock Entry Type        -> no Stock Entry (and so no barcode scan on SE)
  * barcode Client Scripts  -> shipped disabled, so the scan field did nothing
  * removed POS scan method -> Delivery Note / Stock Entry scan called a method
                               that ERPNext v16 no longer has ("Method not found")

It also creates the demo evidence a reviewer needs: item barcodes, a Barcode
Printing document, stock, a scan-validated Delivery Note, a scan-flagged Stock
Entry and an e-invoice (XRECHNUNG) Sales Invoice.
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

COMPANY = os.environ.get("DEMO_COMPANY", "SHRDC")
CUSTOMER = "Demo Buyer SHRDC"
SUPPLIER = "Demo Supplier SHRDC"
BARCODES = {"PLN-BRACKET": "SHRDC-BRK-0001", "PLN-KIT": "SHRDC-KIT-0001"}

OLD_SCAN_METHOD = "erpnext.selling.page.point_of_sale.point_of_sale.search_serial_or_batch_or_barcode_number"
NEW_SCAN_METHOD = "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.scan_barcode"

log = {"created": [], "already": [], "errors": []}


def note(kind, msg):
    log[kind].append(msg)


def try_step(label, fn):
    try:
        result = fn()
        if result is False:
            note("already", label)
        else:
            note("created", "%s -> %s" % (label, result))
        return result
    except Exception as exc:  # never break the build over demo data
        note("errors", "%s: %s: %s" % (label, type(exc).__name__, str(exc)[:300]))
        return None


# ── 1. Supplier Group tree ───────────────────────────────────────────────────
def supplier_groups():
    created = []
    for name, parent, is_group in (
        ("All Supplier Groups", None, 1),
        ("Demo Goods", "All Supplier Groups", 0),
        ("Demo Services", "All Supplier Groups", 0),
    ):
        if frappe.db.exists("Supplier Group", name):
            continue
        frappe.get_doc({
            "doctype": "Supplier Group",
            "supplier_group_name": name,
            "parent_supplier_group": parent,
            "is_group": is_group,
        }).insert(ignore_permissions=True)
        created.append(name)
    frappe.db.commit()
    return ", ".join(created) if created else False


try_step("supplier groups", supplier_groups)


# ── 2. Stock Entry Type fixtures ────────────────────────────────────────────
SE_TYPES = [
    "Material Issue", "Material Receipt", "Material Transfer",
    "Material Transfer for Manufacture", "Material Consumption for Manufacture",
    "Manufacture", "Repack", "Send to Subcontractor", "Disassemble",
]


def stock_entry_types():
    created = []
    for name in SE_TYPES:
        if frappe.db.exists("Stock Entry Type", name):
            continue
        doc = frappe.get_doc({"doctype": "Stock Entry Type", "purpose": name})
        doc.name = name
        doc.flags.name_set = True
        doc.insert(ignore_permissions=True, set_name=name)
        created.append(name)
    frappe.db.commit()
    return ", ".join(created) if created else False


try_step("stock entry types", stock_entry_types)


# ── 3. Barcode client scripts: enabled + scanning on a method that exists ───
def barcode_client_scripts():
    touched = []
    for name in ("Delivery Note-Client", "Stock Entry-Client", "Purchase Receipt-Client", "Work Order-Client"):
        if not frappe.db.exists("Client Script", name):
            continue
        doc = frappe.get_doc("Client Script", name)
        changed = False
        if not doc.enabled:
            doc.enabled = 1
            changed = True
        if OLD_SCAN_METHOD in (doc.script or ""):
            doc.script = doc.script.replace(OLD_SCAN_METHOD, NEW_SCAN_METHOD)
            changed = True
        if changed:
            doc.save(ignore_permissions=True)
            touched.append(name)
    frappe.db.commit()
    return ", ".join(touched) if touched else False


try_step("barcode client scripts", barcode_client_scripts)


# ── 4. Item barcodes (scan targets) ────────────────────────────────────────
def item_barcodes():
    added = []
    for item_code, barcode in BARCODES.items():
        if not frappe.db.exists("Item", item_code):
            continue
        if frappe.db.exists("Item Barcode", {"barcode": barcode}):
            continue
        doc = frappe.get_doc("Item", item_code)
        doc.append("barcodes", {"barcode": barcode, "barcode_type": "CODE128"})
        doc.save(ignore_permissions=True)
        added.append(barcode)
    frappe.db.commit()
    return ", ".join(added) if added else False


try_step("item barcodes", item_barcodes)


# ── 5. Barcode Printing demo document ──────────────────────────────────────
def barcode_printing():
    if frappe.db.exists("Barcode Printing", {"company": COMPANY}):
        return False
    rows = []
    for item_code, barcode in BARCODES.items():
        if not frappe.db.exists("Item", item_code):
            continue
        rows.append({
            "item_code": item_code,
            "item_name": frappe.db.get_value("Item", item_code, "item_name"),
            "barcode": barcode,
            "barcode_type": "CODE128",
            "qty": 2,
            "uom": "Nos",
            "rate": frappe.db.get_value("Item", item_code, "standard_rate") or 10,
            "basic_rate": frappe.db.get_value("Item", item_code, "standard_rate") or 10,
            "conversion_factor": 1,
            "warehouse": "Stores - " + COMPANY,
        })
    if not rows:
        return False
    doc = frappe.get_doc({
        "doctype": "Barcode Printing",
        "naming_series": "BP-.YYYY.-.MM.-.DD.-",
        "company": COMPANY,
        "show_sku": 1,
        "items": rows,
    })
    doc.insert(ignore_permissions=True)
    frappe.db.commit()
    return doc.name


try_step("barcode printing document", barcode_printing)


# ── 6. Stock so barcode-validated Delivery Notes can submit ────────────────
def stock_receipts():
    made = []
    for warehouse, qty in (("Finished Goods - " + COMPANY, 10), ("Stores - " + COMPANY, 5)):
        exists = frappe.db.sql(
            """select se.name from `tabStock Entry` se
               join `tabStock Entry Detail` sed on sed.parent = se.name
               where se.docstatus = 1 and se.stock_entry_type = 'Material Receipt'
                 and sed.t_warehouse = %s and sed.item_code = 'PLN-BRACKET' limit 1""",
            warehouse,
        )
        if exists:
            continue
        doc = frappe.get_doc({
            "doctype": "Stock Entry",
            "stock_entry_type": "Material Receipt",
            "company": COMPANY,
            "items": [{
                "item_code": "PLN-BRACKET", "qty": qty, "uom": "Nos",
                "t_warehouse": warehouse, "basic_rate": 12.5,
            }],
        })
        doc.insert(ignore_permissions=True)
        doc.submit()
        made.append("%s x%s" % (warehouse, qty))
    frappe.db.commit()
    return ", ".join(made) if made else False


try_step("stock receipts", stock_receipts)


# ── 7. Customers / suppliers ───────────────────────────────────────────────
def party_masters():
    made = []
    if not frappe.db.exists("Customer", CUSTOMER):
        frappe.get_doc({
            "doctype": "Customer",
            "customer_name": CUSTOMER,
            "customer_group": "Individual",
            "territory": "Rest Of The World",
            "customer_type": "Company",
            "email_id": "demo.buyer@shrdc.local",
        }).insert(ignore_permissions=True)
        made.append(CUSTOMER)
    if not frappe.db.exists("Supplier", SUPPLIER):
        frappe.get_doc({
            "doctype": "Supplier",
            "supplier_name": SUPPLIER,
            "supplier_group": "Demo Goods",
            "country": "Malaysia",
        }).insert(ignore_permissions=True)
        made.append(SUPPLIER)
    frappe.db.commit()
    return ", ".join(made) if made else False


try_step("customer + supplier", party_masters)


# ── 8. Scan-validated Delivery Note ────────────────────────────────────────
def delivery_note():
    if frappe.db.exists("Delivery Note", {"customer": CUSTOMER, "docstatus": 1}):
        return False
    doc = frappe.get_doc({
        "doctype": "Delivery Note",
        "customer": CUSTOMER,
        "company": COMPANY,
        "barcode_validation": 1,
        "items": [{
            "item_code": "PLN-BRACKET", "qty": 2, "checking_qty": 2,
            "warehouse": "Finished Goods - " + COMPANY, "uom": "Nos", "rate": 12.5,
        }],
    })
    doc.insert(ignore_permissions=True)
    doc.submit()
    frappe.db.commit()
    return doc.name


try_step("barcode-validated delivery note", delivery_note)


# ── 9. Scan-flagged Stock Entry (Material Transfer) ────────────────────────
def stock_entry_transfer():
    if frappe.db.exists("Stock Entry", {"stock_entry_type": "Material Transfer", "docstatus": 1}):
        return False
    doc = frappe.get_doc({
        "doctype": "Stock Entry",
        "stock_entry_type": "Material Transfer",
        "company": COMPANY,
        "scan_stock_entry_barcode": 1,
        "items": [{
            "item_code": "PLN-BRACKET", "qty": 1, "uom": "Nos",
            "s_warehouse": "Stores - " + COMPANY,
            "t_warehouse": "Work In Progress - " + COMPANY,
            "checking_qty": 1,
        }],
    })
    doc.insert(ignore_permissions=True)
    doc.submit()
    frappe.db.commit()
    return doc.name


try_step("scan-flagged stock entry", stock_entry_transfer)


# ── 10. E-invoice demo invoice ─────────────────────────────────────────────
def einvoice_demo():
    settings = frappe.get_single("E Invoice Settings")
    if settings.meta.has_field("auto_attach_xml") and not settings.auto_attach_xml:
        settings.auto_attach_xml = 1
        settings.save(ignore_permissions=True)
        frappe.db.commit()

    if frappe.db.exists("Sales Invoice", {"einvoice_profile": "XRECHNUNG", "docstatus": 1}):
        return False
    doc = frappe.get_doc({
        "doctype": "Sales Invoice",
        "customer": CUSTOMER,
        "company": COMPANY,
        "einvoice_profile": "XRECHNUNG",
        "items": [{"item_code": "PLN-KIT", "qty": 1, "rate": 20,
                   "warehouse": "Finished Goods - " + COMPANY}],
    })
    doc.insert(ignore_permissions=True)
    doc.submit()
    frappe.db.commit()
    return doc.name


try_step("e-invoice demo sales invoice", einvoice_demo)

log["counts"] = {
    "Supplier Group": frappe.db.count("Supplier Group"),
    "Stock Entry Type": frappe.db.count("Stock Entry Type"),
    "Client Script (enabled)": len(frappe.get_all("Client Script", filters={"enabled": 1})),
    "Item Barcode": frappe.db.count("Item Barcode"),
    "Barcode Printing": frappe.db.count("Barcode Printing"),
    "Stock Entry": frappe.db.count("Stock Entry"),
    "Delivery Note": frappe.db.count("Delivery Note"),
    "Sales Invoice": frappe.db.count("Sales Invoice"),
}

print(json.dumps(log, indent=1, default=str))
if log["errors"]:
    sys.exit(1)
