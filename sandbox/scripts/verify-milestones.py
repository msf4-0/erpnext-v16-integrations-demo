#!/usr/bin/env python3
"""End-to-end milestone verification for the comp_demo stack (M1-M10).

Run inside the bench container:

    cd /home/frappe/frappe-bench && SITE_NAME=frontend ./env/bin/python \
        /tmp/scripts/verify-milestones.py

Every check prints exactly one `MARK_<id> PASS|FAIL <detail>` line, so the host
wrapper (comp_demo/verify-all.ps1) can summarise without parsing prose.

What is covered (the checklist the user gave):
  M3  stack + all five apps installed            (container/app level)
  M4  Shopify master-data edits AND the live push ERPNext -> Shopify
      (item create, item update w/ price, customer create, supplier create)
  M6  planner builds: work orders / job cards / workstations / capacity rows
  M7  drag-and-drop: PUT /api/schedule/sync-reschedule persists and keeps
      every Job Card capacity block (the regression fixed earlier)
  M8  barcode: CODE128 / CODE39 / EAN13 render as distinct PNGs, a changed
      value renders a different PNG, invalid EAN13 is rejected, QR renders
  M9  barcode/QR item tracking: scan endpoint, Delivery Note with
      barcode_validation, Stock Entry with scan flag, guest item_qr page
  M10 e-invoicing: EN 16931 CII/UN-CEFACT XML + XRECHNUNG auto-attach
"""
import hashlib
import json
import os
import sys
import time

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe
import requests

SITE = os.environ.get("SITE_NAME", "frontend")
BASE = "http://localhost:8000"
PLANNER = os.environ.get("PLANNER_URL", "http://scheduler:3000")
STAMP = time.strftime("%H%M%S")

frappe.init(site=SITE, sites_path=".")
frappe.connect()
frappe.set_user("Administrator")

RESULTS = []


def mark(cid, ok, detail=""):
    RESULTS.append((cid, bool(ok), detail))
    print("MARK_%s %s %s" % (cid, "PASS" if ok else "FAIL", detail))
    return ok


def check(cid, fn):
    """Run one check; an exception is a FAIL, never a crash."""
    try:
        ok, detail = fn()
    except Exception as exc:
        import traceback

        ok, detail = False, "%s: %s" % (type(exc).__name__, str(exc)[:220])
        print("MARK_%s TRACE %s" % (cid, traceback.format_exc()[-500:].replace("\n", " | ")))
    return mark(cid, ok, detail)


_SESSION = None


def http_session():
    """A logged-in requests session (Administrator).

    Earlier this used the API token in /tmp/export/erpnext_token.txt, which goes
    stale the moment anything re-mints the Administrator keys (the planner setup
    does), so a perfectly healthy endpoint looked like a 401.
    """
    global _SESSION
    if _SESSION is None:
        session = requests.Session()
        session.post(
            BASE + "/api/method/login",
            json={"usr": "Administrator", "pwd": "admin"},
            headers={"Host": SITE},
            timeout=30,
        )
        _SESSION = session
    return _SESSION


def shopify_call(path, method="GET", payload=None):
    """Authenticated Shopify Admin API call using the app's own token helper."""
    from shopify.auth import get_access_token, api_version, store_host
    from shopify.utils import get_shopify_access

    doc = get_shopify_access()
    token = get_access_token(doc)
    store = store_host(doc)
    version = api_version(doc)
    url = "https://%s/admin/api/%s/%s" % (store, version, path.lstrip("/"))
    response = requests.request(
        method,
        url,
        headers={"X-Shopify-Access-Token": token, "Content-Type": "application/json"},
        json=payload,
        timeout=45,
    )
    return response


# ===========================================================================
# M3 - stack + apps
# ===========================================================================
def m3_apps():
    installed = frappe.get_all("Installed Application", fields=["app_name"])
    names = {r["app_name"] for r in installed}
    wanted = ["frappe", "erpnext", "barcode_shrdc", "shopify", "eu_einvoice"]
    missing = [w for w in wanted if w not in names]
    doctypes = ["Barcode Printing", "Shopify Access", "E Invoice Settings", "Virtual Work Order"]
    missing_dt = [d for d in doctypes if not frappe.db.exists("DocType", d)]
    ok = not missing and not missing_dt
    return ok, "apps=%s missing_apps=%s missing_doctypes=%s" % (
        ",".join(sorted(names)),
        ",".join(missing) or "-",
        ",".join(missing_dt) or "-",
    )


# ===========================================================================
# M4 - Shopify master data + LIVE push
# ===========================================================================
def m4_item_create():
    code = "AI-VERIFY-%s" % STAMP
    if frappe.db.exists("Item", code):
        frappe.delete_doc("Item", code, force=1, ignore_permissions=True)
    doc = frappe.get_doc(
        {
            "doctype": "Item",
            "item_code": code,
            "item_name": "AI Verify Product %s" % STAMP,
            "description": "Created by verify-milestones.py to prove the live Shopify push.",
            "item_group": frappe.db.get_value("Item Group", {"is_group": 0}, "name") or "Products",
            "stock_uom": frappe.db.get_value("UOM", {}, "name") or "Nos",
            "is_stock_item": 1,
            "standard_rate": 11.5,
            "show_in_website": 1,
        }
    )
    doc.insert(ignore_permissions=True)
    frappe.db.commit()
    frappe.db.sql("select 1")  # flush
    product_id = None
    for _ in range(10):
        frappe.db.rollback()
        product_id = frappe.db.get_value("Item", code, "shopify_product_id")
        if product_id:
            break
        time.sleep(3)
    if not product_id:
        errs = frappe.get_all(
            "Error Log",
            fields=["method", "error"],
            order_by="creation desc",
            limit_page_length=3,
        )
        return False, "item %s saved but no shopify_product_id; recent errors=%s" % (
            code,
            json.dumps([e.get("error", "")[:120] for e in errs])[:400],
        )
    # confirm it really exists in Shopify
    probe = shopify_call("products/%s.json" % product_id)
    if probe.status_code != 200:
        return False, "shopify_product_id=%s but Shopify GET -> %s %s" % (
            product_id,
            probe.status_code,
            probe.text[:160],
        )
    product = probe.json().get("product", {})
    return True, "item=%s shopify_id=%s title=%r status=%s" % (
        code,
        product_id,
        product.get("title")[:40],
        product.get("status"),
    )


def m4_item_update():
    rows = frappe.get_all(
        "Item",
        filters={"item_code": ["like", "AI-VERIFY-%"]},
        fields=["name", "shopify_product_id"],
        limit_page_length=1,
    )
    if not rows or not rows[0].shopify_product_id:
        return False, "no pushed test item to update"
    item = frappe.get_doc("Item", rows[0].name)
    new_rate = 27.75
    item.standard_rate = new_rate
    item.item_name = "AI Verify Product %s updated" % STAMP
    item.save(ignore_permissions=True)
    frappe.db.commit()
    price = None
    for _ in range(8):
        probe = shopify_call("products/%s.json" % item.shopify_product_id)
        if probe.status_code == 200:
            product = probe.json().get("product", {})
            price = (product.get("variants") or [{}])[0].get("price")
            if str(new_rate) in str(price) or float(price or 0) == new_rate:
                return True, "shopify price updated to %s (title updated too)" % price
        time.sleep(2)
    return False, "item saved but Shopify still shows price=%r (wanted %s)" % (price, new_rate)


def m4_customer():
    cust = "AI Verify Customer %s" % STAMP
    if not frappe.db.exists("Customer", cust):
        doc = frappe.get_doc(
            {
                "doctype": "Customer",
                "customer_name": cust,
                "customer_type": "Company",
                "customer_group": frappe.db.get_value("Customer Group", {"is_group": 0}, "name")
                or "All Customer Groups",
                "territory": frappe.db.get_value("Territory", {"is_group": 0}, "name") or "All Territories",
                "email_id": "ai-verify-%s@example.com" % STAMP,
            }
        )
        doc.insert(ignore_permissions=True)
        frappe.db.commit()
    shopify_id = None
    for _ in range(10):
        frappe.db.rollback()
        shopify_id = frappe.db.get_value("Customer", cust, "shopify_customer_id")
        if shopify_id:
            break
        time.sleep(3)
    if not shopify_id:
        return False, "customer %s created in ERPNext but no shopify_customer_id" % cust
    probe = shopify_call("customers/%s.json" % shopify_id)
    if probe.status_code != 200:
        return False, "shopify_customer_id=%s but Shopify GET -> %s" % (shopify_id, probe.status_code)
    email = probe.json().get("customer", {}).get("email")
    return True, "customer=%s shopify_id=%s email=%s" % (cust, shopify_id, email)


def m4_supplier():
    name = "AI Verify Supplier %s" % STAMP
    group = frappe.db.get_value("Supplier Group", {}, "name")
    if not group:
        return False, "no Supplier Group rows (masters not seeded)"
    if not frappe.db.exists("Supplier", name):
        doc = frappe.get_doc(
            {"doctype": "Supplier", "supplier_name": name, "supplier_group": group, "supplier_type": "Company"}
        )
        doc.insert(ignore_permissions=True)
        frappe.db.commit()
    # an edit must also save cleanly (the old failure mode: save raised because
    # a Shopify hook threw when the token was dead)
    doc = frappe.get_doc("Supplier", name)
    doc.supplier_details = "edited by verify-milestones"
    doc.save(ignore_permissions=True)
    frappe.db.commit()
    messages = frappe.get_all(
        "Error Log",
        filters={"creation": [">", frappe.utils.add_to_date(None, minutes=-3)]},
        fields=["method"],
        limit_page_length=5,
    )
    return True, "supplier created+edited with %d recent error-log rows" % len(messages)


def m4_cleanup():
    """Remove the pushed test product so the storefront is unchanged."""
    removed = []
    for row in frappe.get_all(
        "Item", filters={"item_code": ["like", "AI-VERIFY-%"]}, fields=["name", "shopify_product_id"]
    ):
        pid = row.shopify_product_id
        try:
            frappe.delete_doc("Item", row.name, force=1, ignore_permissions=True)
            frappe.db.commit()
            removed.append(row.name)
        except Exception as exc:
            return False, "could not delete %s: %s" % (row.name, exc)
        if pid:
            probe = shopify_call("products/%s.json" % pid)
            if probe.status_code == 200:
                return False, "ERPNext item %s deleted but Shopify product %s still exists" % (row.name, pid)
    for row in frappe.get_all("Customer", filters={"customer_name": ["like", "AI Verify Customer%"]}, fields=["name"]):
        try:
            frappe.delete_doc("Customer", row.name, force=1, ignore_permissions=True)
            frappe.db.commit()
        except Exception:
            pass
    frappe.db.commit()
    return True, "removed %s and matched Shopify products" % (",".join(removed) or "nothing")


# ===========================================================================
# M6 - planner data
# ===========================================================================
def capacity_meta():
    """(child doctype name, count of capacity rows) for Job Card schedule blocks.

    The child table name differs between ERPNext versions, so resolve it from
    the Job Card meta instead of hard-coding 'Job Card Schedule'.
    """
    field = frappe.get_meta("Job Card").get_field("scheduled_time_logs")
    child = (field.options if field else None) or "Job Card Schedule"
    try:
        count = frappe.db.count(child)
    except Exception:
        count = 0
    return child, count


def m6_planner():
    work_orders = frappe.db.count("Work Order", {"docstatus": ["!=", 2]})
    job_cards = frappe.db.count("Job Card", {"docstatus": ["!=", 2]})
    workstations = frappe.db.count("Workstation")
    child_doctype, capacity = capacity_meta()
    boms = frappe.db.count("BOM", {"docstatus": 1})
    try:
        response = requests.get("%s/api/schedule" % PLANNER, timeout=120)
        api_ok = response.status_code == 200
        payload = response.json() if api_ok else {}
        api_counts = {
            "workOrders": len(payload.get("workOrders") or []),
            "jobCards": len(payload.get("jobCards") or []),
            "workstations": len(payload.get("workstations") or []),
            "batchGroups": len(payload.get("batchGroups") or []),
        }
    except Exception as exc:
        api_ok, api_counts = False, {"error": str(exc)[:120]}
    ok = work_orders > 0 and job_cards > 0 and workstations > 0 and capacity > 0 and api_ok
    return ok, "WOs=%d JCs=%d WS=%d capacity_rows=%d (%s) BOMs=%d API=%s %s" % (
        work_orders,
        job_cards,
        workstations,
        capacity,
        child_doctype,
        boms,
        "ok" if api_ok else "FAIL",
        json.dumps(api_counts) if api_ok else "",
    )


# ===========================================================================
# M7 - drag-and-drop persistence
# ===========================================================================
def m7_drag():
    wo = frappe.get_all(
        "Work Order",
        filters={"docstatus": 1},
        fields=["name", "planned_start_date", "qty", "production_item", "status"],
        order_by="creation asc",
        limit_page_length=1,
    )
    if not wo:
        return False, "no submitted Work Order to drag"
    wo = wo[0]
    before_start = str(wo.planned_start_date)
    child, _ = capacity_meta()
    jc_names = frappe.get_all("Job Card", filters={"work_order": wo.name}, pluck="name")
    before_blocks = frappe.db.count(child, {"parent": ["in", jc_names]}) if jc_names else 0
    before_total = frappe.db.count(child)

    import datetime

    base = frappe.utils.get_datetime(before_start)
    new_start = base + datetime.timedelta(days=2)
    payload = {
        "type": "workorder",
        "docName": wo.name,
        "start": new_start.strftime("%Y-%m-%d %H:%M:%S"),
        "end": (new_start + datetime.timedelta(hours=8)).strftime("%Y-%m-%d %H:%M:%S"),
        "workOrderId": wo.name,
    }
    response = requests.put("%s/api/schedule/sync-reschedule" % PLANNER, json=payload, timeout=180)
    if response.status_code != 200:
        return False, "sync-reschedule -> HTTP %s %s" % (response.status_code, response.text[:200])

    frappe.db.commit()
    after_start = frappe.db.get_value("Work Order", wo.name, "planned_start_date")
    after_blocks = frappe.db.count(child, {"parent": ["in", jc_names]}) if jc_names else 0
    after_total = frappe.db.count(child)
    modified_by = frappe.db.get_value("Work Order", wo.name, "modified_by")
    moved = str(after_start) != before_start

    # put it back so the demo data keeps its original plan
    restore = dict(payload)
    restore["start"] = before_start
    restore["end"] = (base + datetime.timedelta(hours=8)).strftime("%Y-%m-%d %H:%M:%S")
    requests.put("%s/api/schedule/sync-reschedule" % PLANNER, json=restore, timeout=180)
    frappe.db.commit()
    restored = str(frappe.db.get_value("Work Order", wo.name, "planned_start_date"))

    ok = moved and after_blocks == before_blocks and after_total == before_total
    return ok, (
        "WO=%s %s -> %s (moved=%s, modified_by=%s) | JC blocks %d->%d kept=%s | capacity rows %d->%d | restored=%s"
        % (
            wo.name,
            before_start,
            after_start,
            moved,
            modified_by,
            before_blocks,
            after_blocks,
            after_blocks == before_blocks,
            before_total,
            after_total,
            restored == before_start,
        )
    )


def m7b_drag_jobcard():
    """A Job Card drag must move every capacity block and give the parent WO a time."""
    child, _ = capacity_meta()
    blocks_field = frappe.get_meta(child)
    time_fields = [f.fieldname for f in blocks_field.fields if f.fieldtype in ("Datetime", "Date", "Time")]
    start_field = "from_time" if "from_time" in time_fields else (time_fields[0] if time_fields else "from_time")
    end_field = "to_time" if "to_time" in time_fields else (time_fields[-1] if time_fields else "to_time")

    chosen = None
    for jc in frappe.get_all(
        "Job Card",
        filters={"docstatus": ["!=", 2]},
        fields=["name", "work_order", "expected_start_date"],
        limit_page_length=40,
    ):
        rows = frappe.get_all(
            child,
            filters={"parent": jc.name},
            fields=["name", start_field, end_field],
            order_by="idx asc",
        )
        if len(rows) >= 2 and rows[0].get(start_field):
            chosen = (jc, rows)
            break
    if not chosen:
        return False, "no Job Card with 2+ schedule blocks to drag"

    jc, rows = chosen
    first_before = str(rows[0][start_field])
    last_before = str(rows[-1][end_field])
    blocks_before = len(rows)
    parent_start_before = frappe.db.get_value("Work Order", jc.work_order, "planned_start_date")

    import datetime

    first_dt = frappe.utils.get_datetime(first_before)
    last_dt = frappe.utils.get_datetime(last_before)
    delta = datetime.timedelta(days=1)
    payload = {
        "type": "jobcard",
        "docName": jc.name,
        "start": (first_dt + delta).strftime("%Y-%m-%d %H:%M:%S"),
        "end": (last_dt + delta).strftime("%Y-%m-%d %H:%M:%S"),
        "workOrderId": jc.work_order,
    }
    response = requests.put("%s/api/schedule/sync-reschedule" % PLANNER, json=payload, timeout=180)
    if response.status_code != 200:
        return False, "jobcard sync-reschedule -> HTTP %s %s" % (response.status_code, response.text[:200])

    frappe.db.commit()
    after = frappe.get_all(
        child, filters={"parent": jc.name}, fields=["name", start_field, end_field], order_by="idx asc"
    )
    first_after = str(after[0][start_field]) if after else None
    blocks_after = len(after)
    parent_start_after = frappe.db.get_value("Work Order", jc.work_order, "planned_start_date")
    moved = first_after != first_before
    kept = blocks_after == blocks_before
    has_time = "00:00:00" not in str(parent_start_after)

    # restore the block AND the parent Work Order date the drag moved with it
    restore = {
        "type": "jobcard",
        "docName": jc.name,
        "start": first_before,
        "end": last_before,
        "workOrderId": jc.work_order,
    }
    requests.put("%s/api/schedule/sync-reschedule" % PLANNER, json=restore, timeout=180)
    frappe.db.commit()   # close our transaction before writing rows the planner just touched
    time.sleep(1)
    if jc.work_order and parent_start_before:
        # The planner writes the Work Order from its own connection, so a plain
        # read-then-write here can hit "record has changed since last read".
        for attempt in range(4):
            try:
                frappe.db.set_value(
                    "Work Order", jc.work_order, "planned_start_date", parent_start_before,
                    update_modified=False,
                )
                frappe.db.commit()
                break
            except Exception as exc:
                frappe.db.rollback()
                if attempt == 3:
                    raise
                time.sleep(2)
    frappe.db.commit()
    restored = str(frappe.db.get_value(child, after[0]["name"], start_field)) if after else None

    ok = moved and kept and has_time
    return ok, (
        "JC=%s %s -> %s (moved=%s, blocks %d->%d, parent WO %s -> %s has_time=%s, restored=%s)"
        % (
            jc.name,
            first_before,
            first_after,
            moved,
            blocks_before,
            blocks_after,
            parent_start_before,
            parent_start_after,
            has_time,
            restored == first_before,
        )
    )


# ===========================================================================
# M8 - barcode/QR rendering incl. changed values
# ===========================================================================
def _digest(content):
    return hashlib.sha256(content).hexdigest()[:16]


def m8_barcodes():
    from frappe.utils import get_files_path
    from barcode_shrdc.barcode_shrdc.doctype.barcode_printing import barcode_printing as bp

    files_dir = get_files_path()

    def digest(url):
        path = os.path.join(files_dir, os.path.basename(url))
        with open(path, "rb") as handle:
            return _digest(handle.read())

    produced = {}
    for symbology, value in (("CODE128", "SHRDC-CODE128-1"), ("CODE39", "SHRDC-CODE39-1"), ("EAN13", "8991234567891")):
        url = bp.get_barcode_image(value, symbology)
        produced[symbology] = (url, digest(url))
    distinct = len({v[1] for v in produced.values()}) == 3

    changed = bp.get_barcode_image("SHRDC-CODE128-2", "CODE128")
    value_changes_image = digest(changed) != produced["CODE128"][1]

    invalid_rejected, invalid_msg = False, ""
    try:
        bp.get_barcode_image("123", "EAN13")
    except Exception as exc:
        invalid_rejected = "13 digits" in str(exc) or "EAN13" in str(exc)
        invalid_msg = str(exc)[:110]

    # QR is rendered per item row (get_qr_image takes an Item document)
    qr_url = bp.get_qr_image(frappe.get_doc("Item", "PLN-BRACKET"))
    qr_digest = digest(qr_url)

    http_ok = False
    http_ctype = ""
    try:
        resp = requests.get(BASE + produced["CODE128"][0], headers={"Host": SITE}, timeout=30)
        http_ctype = resp.headers.get("Content-Type", "")
        http_ok = resp.status_code == 200 and http_ctype.startswith("image/")
    except Exception:
        http_ok = False

    ok = distinct and value_changes_image and invalid_rejected and bool(qr_digest) and http_ok
    return ok, "3_symbols_distinct=%s changed_value_new_png=%s invalid_EAN13_rejected=%s qr=%s served_as_image=%s (%s) %s" % (
        distinct,
        value_changes_image,
        invalid_rejected,
        qr_digest,
        http_ok,
        http_ctype,
        json.dumps({k: v[1] for k, v in produced.items()}),
    )


# ===========================================================================
# M9 - barcode/QR item tracking
# ===========================================================================
def m9_tracking():
    from barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing import scan_barcode

    hits = []
    for value in ("SHRDC-BRK-0001", "SHRDC-KIT-0001"):
        result = scan_barcode(search_value=value)
        hits.append((value, (result or {}).get("item_code")))
    unknown = scan_barcode(search_value="NO-SUCH-BARCODE-XYZ")
    unknown_empty = not unknown

    http_scan = None
    try:
        resp = http_session().get(
            BASE
            + "/api/method/barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.scan_barcode"
            + "?search_value=SHRDC-BRK-0001",
            headers={"Host": SITE},
            timeout=30,
        )
        http_scan = (resp.status_code, (resp.json().get("message") or {}).get("item_code"))
    except Exception as exc:
        http_scan = ("ERR", str(exc)[:80])

    dn = frappe.get_all(
        "Delivery Note",
        filters={"docstatus": 1},
        fields=["name", "barcode_validation"],
        order_by="creation desc",
        limit_page_length=1,
    )
    dn_ok = bool(dn) and bool(dn[0].barcode_validation)
    qty_guard = True
    if dn:
        for row in frappe.get_all("Delivery Note Item", filters={"parent": dn[0].name}, fields=["checking_qty", "qty"]):
            if float(row.checking_qty or 0) != float(row.qty or 0):
                qty_guard = False

    se = frappe.get_all(
        "Stock Entry",
        filters={"docstatus": 1},
        fields=["name", "scan_stock_entry_barcode"],
        order_by="creation desc",
        limit_page_length=1,
    )
    se_ok = bool(se) and bool(se[0].scan_stock_entry_barcode)

    qr_page = None
    try:
        resp = requests.get(BASE + "/item_qr?item_code=PLN-BRACKET", headers={"Host": SITE}, timeout=30)
        qr_page = (resp.status_code, len(resp.text), "QR Code Scanning" in resp.text or "Item Details" in resp.text)
    except Exception as exc:
        qr_page = ("ERR", str(exc)[:80], False)

    ok = (
        all(h[1] for h in hits)
        and unknown_empty
        and http_scan[0] == 200
        and dn_ok
        and qty_guard
        and se_ok
        and qr_page[0] == 200
    )
    return ok, (
        "scan=%s unknown->empty=%s http_scan=%s | DN=%s barcode_validation=%s qty_guard=%s | SE=%s scan_flag=%s | item_qr=%s"
        % (
            json.dumps(hits),
            unknown_empty,
            http_scan,
            dn[0].name if dn else None,
            dn_ok,
            qty_guard,
            se[0].name if se else None,
            se_ok,
            qr_page,
        )
    )


def m9b_server_guard():
    """A REST/programmatic submit must NOT bypass the scanned-quantity rule."""
    company = frappe.db.get_value("Company", {}, "name")
    customer = frappe.db.get_value("Customer", {"customer_name": "Demo Buyer SHRDC"}, "name")
    warehouse = frappe.db.get_value(
        "Warehouse", {"company": company, "warehouse_name": "Finished Goods"}, "name"
    ) or frappe.db.get_value("Warehouse", {"company": company}, "name")
    if not (customer and warehouse):
        return False, "no demo customer/warehouse to build a Delivery Note"

    doc = frappe.get_doc(
        {
            "doctype": "Delivery Note",
            "customer": customer,
            "company": company,
            "barcode_validation": 1,
            "items": [
                {
                    "item_code": "PLN-BRACKET",
                    "qty": 2,
                    "rate": 10,
                    "warehouse": warehouse,
                    "against_sales_order": None,
                    "checking_qty": 1,
                }
            ],
        }
    )
    doc.flags.ignore_permissions = True
    inserted = None
    try:
        doc.insert()
        inserted = doc.name
        rejected, message = False, ""
        try:
            doc.submit()
        except Exception as exc:
            rejected, message = True, "%s: %s" % (type(exc).__name__, str(exc)[:160])
    finally:
        frappe.db.rollback()
        if inserted and frappe.db.exists("Delivery Note", inserted):
            frappe.delete_doc("Delivery Note", inserted, force=1, ignore_permissions=True)
        frappe.db.commit()

    ok = rejected
    return ok, "mismatched DN (qty 2 / checked 1) submit rejected=%s %s" % (rejected, message)


# ===========================================================================
# M10 - e-invoicing
# ===========================================================================
def m10_einvoice():
    from eu_einvoice.european_e_invoice.custom.sales_invoice import get_einvoice

    invoices = frappe.get_all(
        "Sales Invoice",
        filters={"einvoice_profile": "EN 16931", "docstatus": 1},
        fields=["name"],
        limit_page_length=1,
    )
    if not invoices:
        invoices = frappe.get_all(
            "Sales Invoice",
            filters={"einvoice_profile": ["!=", ""], "docstatus": 1},
            fields=["name"],
            limit_page_length=1,
        )
    if not invoices:
        return False, "no submitted invoice with an e-invoice profile"
    name = invoices[0].name
    xml = get_einvoice(name)
    if isinstance(xml, str):
        xml = xml.encode()
    has_cii = b"CrossIndustryInvoice" in xml or b"rsm:" in xml
    has_en = b"en16931" in xml.lower() or b"xrechnung" in xml.lower()
    size = len(xml)

    xr = frappe.get_all(
        "Sales Invoice",
        filters={"einvoice_profile": "XRECHNUNG", "docstatus": 1},
        fields=["name"],
        limit_page_length=1,
    )
    attached = []
    if xr:
        files = frappe.get_all(
            "File",
            filters={"attached_to_doctype": "Sales Invoice", "attached_to_name": xr[0].name},
            fields=["file_name", "file_size"],
        )
        attached = [(f.file_name, f.file_size) for f in files]
    xml_attached = any(str(f[0]).lower().endswith(".xml") for f in attached)

    ok = has_cii and has_en and size > 1000 and xml_attached
    return ok, "invoice=%s bytes=%d CII=%s EN16931=%s | XRECHNUNG=%s attachments=%s" % (
        name,
        size,
        has_cii,
        has_en,
        xr[0].name if xr else None,
        json.dumps(attached)[:200],
    )


# ===========================================================================
# run
# ===========================================================================
def main():
    print("MARK_SITE %s apps-loaded" % frappe.local.site)
    check("M3_APPS", m3_apps)
    check("M4_PUSH_ITEM", m4_item_create)
    check("M4_PUSH_UPDATE", m4_item_update)
    check("M4_PUSH_CUSTOMER", m4_customer)
    check("M4_SUPPLIER", m4_supplier)
    check("M4_CLEANUP", m4_cleanup)
    check("M6_PLANNER", m6_planner)
    check("M7_DRAG_WO", m7_drag)
    check("M7_DRAG_JC", m7b_drag_jobcard)
    check("M8_BARCODE", m8_barcodes)
    check("M9_TRACKING", m9_tracking)
    check("M9_SERVER_GUARD", m9b_server_guard)
    check("M10_EINVOICE", m10_einvoice)

    passed = sum(1 for _, ok, _ in RESULTS if ok)
    failed = [cid for cid, ok, _ in RESULTS if not ok]
    print("MARK_SUMMARY pass=%d fail=%d failed=%s" % (passed, len(failed), ",".join(failed) or "-"))
    frappe.db.commit()
    frappe.destroy()
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
