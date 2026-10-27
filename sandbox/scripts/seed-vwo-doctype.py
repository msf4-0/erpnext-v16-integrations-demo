#!/usr/bin/env python3
"""Create the `Virtual Work Order` doctype the production planner expects.

WHY: the planner (`F:\\ERPNEXT\\ERPNEXT-AI-FIX\\scheduler`) was migrated from its
own JSON store to an ERPNext doctype, and its server code reads/writes
`/Virtual Work Order` for three features:

  * batch groups  - one Virtual Work Order master with N sub-Work-Orders
                    (POST /api/batch-work-orders, the "Batch" view filter)
  * timers        - the group a running timer belongs to (GET /api/work-orders/timers)
  * schedule feed - the batch-group cards on the matrix/calendar
                    (GET /api/schedule -> batchGroups[])

That doctype was never shipped in the site, so every one of those paths hit
`404 /Virtual Work Order` and the planner silently degraded (console.warn,
empty batch list). This script creates it - plus its child table - directly in
the site, idempotently, so a rebuilt site gets the schema again.

Run inside the bench container:

    cd /home/frappe/frappe-bench && SITE_NAME=frontend ./env/bin/python \
        /tmp/scripts/seed-vwo-doctype.py

Field names are copied from the planner's request payloads:
  server.js  batch-work-orders  -> production_item, bom_no, planned_date,
                                   workstation, qty_per_batch, batch_count,
                                   total_qty, is_virtual_master, sub_wos[]
  server.js  GET /api/schedule  -> name, creation, docstatus, master_wo,
                                   sub_wos[].sub_wo, sub_wos[].batch_number,
                                   sub_wos[].status
"""
import os
import sys

import frappe

SITE = os.environ.get("SITE_NAME", "frontend")
os.chdir("/home/frappe/frappe-bench/sites")
frappe.init(site=SITE, sites_path=".")
frappe.connect()
frappe.set_user("Administrator")

PARENT = "Virtual Work Order"
CHILD = "Virtual Work Order Sub"
STATUS_OPTIONS = "Draft\nIn Process\nCompleted\nFailed"

log = {"created": [], "already": [], "errors": []}


def note(kind, msg):
    log[kind].append(msg)


# ---------------------------------------------------------------------------
# schema
# ---------------------------------------------------------------------------
def child_fields():
    return [
        {
            "fieldname": "sub_wo",
            "label": "Sub Work Order",
            "fieldtype": "Link",
            "options": "Work Order",
            "reqd": 1,
            "in_list_view": 1,
            "columns": 3,
        },
        {
            "fieldname": "batch_number",
            "label": "Batch Number",
            "fieldtype": "Int",
            "in_list_view": 1,
            "columns": 1,
        },
        {
            "fieldname": "status",
            "label": "Status",
            "fieldtype": "Select",
            "options": STATUS_OPTIONS,
            "default": "Draft",
            "in_list_view": 1,
            "columns": 2,
        },
    ]


def parent_fields():
    return [
        {
            "fieldname": "master_wo",
            "label": "Master Work Order",
            "fieldtype": "Link",
            "options": "Work Order",
            "read_only": 1,
        },
        {
            "fieldname": "production_item",
            "label": "Production Item",
            "fieldtype": "Link",
            "options": "Item",
            "reqd": 1,
            "in_list_view": 1,
            "in_standard_filter": 1,
        },
        {
            "fieldname": "bom_no",
            "label": "BOM No",
            "fieldtype": "Link",
            "options": "BOM",
        },
        {
            "fieldname": "planned_date",
            "label": "Planned Date",
            "fieldtype": "Date",
            "in_list_view": 1,
            "in_standard_filter": 1,
        },
        {
            "fieldname": "workstation",
            "label": "Workstation",
            "fieldtype": "Link",
            "options": "Workstation",
            "in_list_view": 1,
            "in_standard_filter": 1,
        },
        {
            "fieldname": "column_break_qty",
            "label": "",
            "fieldtype": "Column Break",
        },
        {
            "fieldname": "qty_per_batch",
            "label": "Qty Per Batch",
            "fieldtype": "Float",
            "in_list_view": 1,
        },
        {
            "fieldname": "batch_count",
            "label": "Batch Count",
            "fieldtype": "Int",
            "in_list_view": 1,
        },
        {
            "fieldname": "total_qty",
            "label": "Total Qty",
            "fieldtype": "Float",
        },
        {
            "fieldname": "is_virtual_master",
            "label": "Is Virtual Master",
            "fieldtype": "Check",
            "default": "1",
        },
        {
            "fieldname": "section_break_sub",
            "label": "Sub Work Orders",
            "fieldtype": "Section Break",
        },
        {
            "fieldname": "sub_wos",
            "label": "Sub Work Orders",
            "fieldtype": "Table",
            "options": CHILD,
        },
    ]


def build_doctype(name, fields, is_child=False):
    """Insert or update one DocType definition and run the DDL for it."""
    # Frappe's naming-series validator requires a dot in the literal part, so
    # the counter form is "VWO-.####" (renders VWO-0001), not "VWO-{####}".
    autono = "hash" if is_child else "VWO-.####"
    payload = {
        "doctype": "DocType",
        "name": name,
        "module": "Manufacturing",
        "custom": 1,
        "istable": 1 if is_child else 0,
        "is_submittable": 0 if is_child else 1,
        "engine": "InnoDB",
        "allow_rename": 0,
        "track_changes": 1,
        "editable_grid": 1,
        "autoname": autono,
        "fields": fields,
        "permissions": []
        if is_child
        else [
            {
                "role": "System Manager",
                "read": 1,
                "write": 1,
                "create": 1,
                "delete": 1,
                "submit": 1,
                "cancel": 1,
                "amend": 1,
                "report": 1,
                "export": 1,
                "share": 1,
                "print": 1,
                "email": 1,
            },
            {
                "role": "Manufacturing Manager",
                "read": 1,
                "write": 1,
                "create": 1,
                "submit": 1,
                "cancel": 1,
                "report": 1,
                "export": 1,
                "print": 1,
                "email": 1,
            },
            {
                "role": "Manufacturing User",
                "read": 1,
                "write": 1,
                "create": 1,
                "report": 1,
                "export": 1,
                "print": 1,
                "email": 1,
            },
        ],
    }

    exists = frappe.db.exists("DocType", name)
    if exists:
        doc = frappe.get_doc("DocType", name)
        doc.update(payload)
        doc.flags.ignore_permissions = True
        doc.save()
        note("already", "%s (fields synced)" % name)
    else:
        doc = frappe.get_doc(payload)
        doc.flags.ignore_permissions = True
        doc.insert()
        note("created", name)

    # Inserting a DocType does not always run the DDL on a freshly provisioned
    # site; updatedb() is explicit and idempotent.
    frappe.db.updatedb(name)
    frappe.db.commit()
    return name


def verify_schema():
    for dt in (CHILD, PARENT):
        cols = {c["Field"] for c in frappe.db.sql("SHOW COLUMNS FROM `tab%s`" % dt, as_dict=True)}
        if not cols:
            raise RuntimeError("%s has no table" % dt)
        print("MARK_TABLE %s cols=%d" % (dt, len(cols)))
    meta = frappe.get_meta(PARENT)
    wanted = ["master_wo", "production_item", "bom_no", "planned_date", "workstation",
              "qty_per_batch", "batch_count", "total_qty", "is_virtual_master", "sub_wos"]
    missing = [f for f in wanted if not meta.has_field(f)]
    if missing:
        raise RuntimeError("Virtual Work Order missing fields: %s" % ", ".join(missing))
    print("MARK_FIELDS ok count=%d submittable=%s" % (len(meta.fields), meta.is_submittable))


# ---------------------------------------------------------------------------
# demo evidence: one batch group built from two real Work Orders
# ---------------------------------------------------------------------------
def seed_demo_batch_group():
    if frappe.db.count(PARENT) > 0:
        note("already", "demo batch group")
        return None
    wos = frappe.get_all(
        "Work Order",
        filters={"docstatus": 1, "status": ["in", ["Not Started", "In Process", "Draft"]]},
        fields=["name", "production_item", "bom_no", "planned_start_date", "qty"],
        order_by="creation asc",
        limit_page_length=2,
    )
    if len(wos) < 2:
        wos = frappe.get_all(
            "Work Order",
            filters={"docstatus": ["!=", 2]},
            fields=["name", "production_item", "bom_no", "planned_start_date", "qty"],
            order_by="creation asc",
            limit_page_length=2,
        )
    if not wos:
        note("errors", "demo batch group: no Work Orders to group")
        return None

    first = wos[0]
    planned = str(first.planned_start_date or frappe.utils.today())[:10]
    doc = frappe.get_doc(
        {
            "doctype": PARENT,
            "production_item": first.production_item,
            "bom_no": first.bom_no,
            "planned_date": planned,
            "workstation": frappe.db.get_value("Workstation", {}, "name") or "",
            "qty_per_batch": first.qty or 10,
            "batch_count": len(wos),
            "total_qty": sum(float(w.qty or 0) for w in wos),
            "is_virtual_master": 1,
            "sub_wos": [
                {"sub_wo": w.name, "batch_number": i + 1, "status": "Draft"}
                for i, w in enumerate(wos)
            ],
        }
    )
    doc.flags.ignore_permissions = True
    doc.insert()
    doc.submit()          # the planner auto-submits its groups (docstatus 1)
    frappe.db.commit()
    note("created", "demo batch group %s (%d sub WOs)" % (doc.name, len(wos)))
    print("MARK_BATCH_GROUP %s | %s | %s | sub_wos=%d | docstatus=%s"
          % (doc.name, doc.production_item, doc.planned_date, len(doc.sub_wos), doc.docstatus))
    return doc.name


# ---------------------------------------------------------------------------
# the planner's schedule-write endpoint
# ---------------------------------------------------------------------------
RESCHEDULE_SCRIPT = r'''
job_card = frappe.form_dict.get("job_card")
blocks = frappe.form_dict.get("blocks") or []
workstation = frappe.form_dict.get("workstation")

if isinstance(blocks, str):
    blocks = frappe.parse_json(blocks)
if not job_card:
    frappe.throw("job_card is required")
if not blocks:
    frappe.throw("blocks is required")

child = frappe.get_meta("Job Card").get_field("scheduled_time_logs").options

shifted = 0
for row in blocks:
    name = (row or {}).get("name")
    from_time = (row or {}).get("from_time")
    to_time = (row or {}).get("to_time")
    if not (name and from_time and to_time):
        continue
    frappe.db.set_value(
        child, name, {"from_time": from_time, "to_time": to_time}, update_modified=False
    )
    shifted += 1

updates = {
    "expected_start_date": blocks[0].get("from_time"),
    "expected_end_date": blocks[-1].get("to_time"),
}
if workstation:
    updates["workstation"] = workstation
frappe.db.set_value("Job Card", job_card, updates, update_modified=True)
frappe.db.commit()

frappe.response["message"] = {"job_card": job_card, "shifted": shifted}
'''


def seed_reschedule_api():
    """Create/refresh the Server Script the planner calls to move a Job Card.

    Writing the child rows directly is deliberate: ERPNext's
    `JobCard.validate_sequence_id` refuses to save a Job Card whose previous
    operation has no completed quantity, so a normal PUT silently skips every
    operation after the first one and a Work Order drag only half-applies.
    """
    name = "planner_shift_job_card"
    api_method = "planner_shift_job_card"
    exists = frappe.db.exists("Server Script", name)
    if exists:
        doc = frappe.get_doc("Server Script", name)
    else:
        doc = frappe.new_doc("Server Script")
        doc.name = name
    doc.script_type = "API"
    doc.api_method = api_method
    doc.allow_guest = 0
    doc.disabled = 0
    doc.script = RESCHEDULE_SCRIPT
    doc.flags.ignore_permissions = True
    doc.save()
    frappe.db.commit()
    note("already" if exists else "created", "Server Script %s" % api_method)
    print("MARK_API %s | script_type=%s disabled=%s" % (name, doc.script_type, doc.disabled))
    return name


def main():
    try:
        build_doctype(CHILD, child_fields(), is_child=True)
        build_doctype(PARENT, parent_fields(), is_child=False)
        frappe.clear_cache()
        verify_schema()
        seed_reschedule_api()
        seed_demo_batch_group()
    except Exception as exc:
        note("errors", "%s: %s" % (type(exc).__name__, exc))
        print("MARK_VWO_ERR %s: %s" % (type(exc).__name__, exc))
        import traceback

        traceback.print_exc()

    total = frappe.db.count(PARENT)
    print("MARK_VWO_TOTAL %d" % total)
    print("MARK_VWO_CREATED %s" % ("; ".join(log["created"]) or "-"))
    print("MARK_VWO_ALREADY %s" % ("; ".join(log["already"]) or "-"))
    print("MARK_VWO_ERRORS %s" % ("; ".join(log["errors"]) or "-"))
    return 1 if log["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
