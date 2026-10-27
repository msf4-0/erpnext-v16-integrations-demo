#!/usr/bin/env python3
"""Repair the demo data left behind by the verification runs.

The verification suite deliberately creates and deletes a test product and a
test customer, and drags Work Orders around. Two things can survive a run:

  * a test Supplier (the suite only cleans item + customer), and
  * a Work Order whose planned date the drag test moved before the deadlock fix
    (which skipped the restore) landed.

This puts the schedule back into its seeded day-by-day sequence and removes the
test suppliers. Idempotent.

    SITE_NAME=frontend ./env/bin/python /tmp/scripts/fix-demo-data.py [--dry-run]
"""
import datetime
import os
import sys

import frappe

SITE = os.environ.get("SITE_NAME", "frontend")
DRY = "--dry-run" in sys.argv
os.chdir("/home/frappe/frappe-bench/sites")
frappe.init(site=SITE, sites_path=".")
frappe.connect()
frappe.set_user("Administrator")

child_doctype = frappe.get_meta("Job Card").get_field("scheduled_time_logs").options

# 1. test suppliers from verify-milestones.py
suppliers = frappe.get_all(
    "Supplier", filters={"supplier_name": ["like", "AI Verify Supplier%"]}, pluck="name"
)
for name in suppliers:
    if not DRY:
        frappe.delete_doc("Supplier", name, force=1, ignore_permissions=True)
print("REPAIR test_suppliers_deleted=%d %s dry_run=%s" % (len(suppliers), suppliers, DRY))

# 2. Work Orders whose planned date is far outside the seeded day-by-day run.
rows = frappe.get_all(
    "Work Order",
    fields=["name", "planned_start_date"],
    order_by="planned_start_date asc",
    limit_page_length=0,
)
if rows:
    dates = sorted(
        frappe.utils.get_datetime(r.planned_start_date) for r in rows if r.planned_start_date
    )
    # median-ish gap of the schedule: the seeded plan is one WO per day
    gaps = [
        (dates[i + 1] - dates[i]).days
        for i in range(len(dates) - 1)
        if 0 < (dates[i + 1] - dates[i]).days <= 3
    ]
    step = max(1, min(gaps)) if gaps else 1
    for row in rows:
        start = frappe.utils.get_datetime(row.planned_start_date)
        previous = [d for d in dates if d < start]
        if not previous:
            continue
        expected = previous[-1] + datetime.timedelta(days=step)
        if (start - previous[-1]).days > step * 2:
            fixed = expected.strftime("%Y-%m-%d 08:00:00")
            print("REPAIR %s: %s -> %s (out of sequence)" % (row.name, row.planned_start_date, fixed))
            if not DRY:
                frappe.db.set_value("Work Order", row.name, "planned_start_date", fixed, update_modified=False)
                for jc in frappe.get_all("Job Card", filters={"work_order": row.name}, pluck="name"):
                    doc = frappe.get_doc("Job Card", jc)
                    logs = sorted(doc.scheduled_time_logs or [], key=lambda b: str(b.from_time))
                    if not logs:
                        continue
                    delta = frappe.utils.get_datetime(fixed) - frappe.utils.get_datetime(
                        str(row.planned_start_date)
                    )
                    for block in logs:
                        frappe.db.set_value(
                            child_doctype,
                            block.name,
                            {
                                "from_time": frappe.utils.get_datetime(str(block.from_time)) + delta,
                                "to_time": frappe.utils.get_datetime(str(block.to_time)) + delta,
                            },
                            update_modified=False,
                        )
                    frappe.db.set_value(
                        "Job Card",
                        jc,
                        {
                            "expected_start_date": frappe.utils.get_datetime(str(logs[0].from_time)) + delta,
                            "expected_end_date": frappe.utils.get_datetime(str(logs[-1].to_time)) + delta,
                        },
                        update_modified=False,
                    )

frappe.db.commit()
print(
    "REPAIR counts work_orders=%d job_cards=%d capacity=%d"
    % (
        frappe.db.count("Work Order"),
        frappe.db.count("Job Card"),
        frappe.db.count(frappe.get_meta("Job Card").get_field("scheduled_time_logs").options),
    )
)
frappe.destroy()
