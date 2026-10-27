#!/usr/bin/env python3
"""Snapshot / restore the Job Card capacity plan (`scheduled_time_logs` rows).

The planner's reschedule path rewrites every Job Card it touches to a SINGLE
schedule row (see install-log/scheduler.md), so the reschedule round-trip in
scheduler-up.ps1's verification erodes the seeded capacity plan a little on every
run (measured: 65 rows -> 64 after one round-trip). This dumps the rows before a
test and puts them back afterwards, which keeps repeated bring-ups idempotent.

    env/bin/python /tmp/planner_capacity_snapshot.py --dump
    env/bin/python /tmp/planner_capacity_snapshot.py --restore
"""
import json
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")
PATH = os.environ.get("SNAPSHOT_PATH", "/tmp/planner_capacity.json")
CHILD = "Job Card Scheduled Time"
COLUMNS = [
    "name",
    "owner",
    "docstatus",
    "idx",
    "parent",
    "from_time",
    "to_time",
    "time_in_mins",
]

frappe.init(site=SITE, sites_path=".")
frappe.connect()
frappe.set_user("Administrator")

mode = sys.argv[1] if len(sys.argv) > 1 else "--dump"


def dump():
    rows = frappe.get_all(
        CHILD,
        fields=["name", "owner", "docstatus", "idx", "parent", "from_time", "to_time", "time_in_mins"],
        order_by="parent, idx",
        limit_page_length=0,
    )
    parents = sorted({r["parent"] for r in rows})
    payload = {"rows": [dict(r) for r in rows], "parents": parents}
    with open(PATH, "w") as fh:
        json.dump(payload, fh, default=str)
    print("MARK dumped %s schedule rows across %s job cards -> %s" % (len(rows), len(parents), PATH))
    print("count rows %s" % len(rows))


def restore():
    if not os.path.exists(PATH):
        raise SystemExit("ERROR: no snapshot at %s - run --dump first" % PATH)
    with open(PATH) as fh:
        payload = json.load(fh)
    rows = payload["rows"]
    parents = payload["parents"]

    placeholders = ", ".join(["%s"] * len(parents))
    frappe.db.sql(
        "delete from `tab%s` where parent in (%s)" % (CHILD, placeholders), tuple(parents)
    )

    columns = ", ".join("`%s`" % c for c in COLUMNS)
    values = ", ".join(["%(" + c + ")s" for c in COLUMNS])
    insert = (
        "insert into `tab{child}` ({cols}, creation, modified, modified_by, parentfield, parenttype) "
        "values ({vals}, now(), now(), 'Administrator', %(parentfield)s, %(parenttype)s)"
    ).format(child=CHILD, cols=columns, vals=values)
    for row in rows:
        record = {c: row.get(c) for c in COLUMNS}
        record["parentfield"] = "scheduled_time_logs"
        record["parenttype"] = "Job Card"
        frappe.db.sql(insert, record)

    for parent in parents:
        job_card = frappe.get_doc("Job Card", parent)
        job_card.set_expected_and_actual_time()
        job_card.db_update()

    frappe.db.commit()
    print("MARK restored %s schedule rows across %s job cards" % (len(rows), len(parents)))
    print("count rows %s" % frappe.db.count(CHILD))


if mode == "--dump":
    dump()
elif mode == "--restore":
    restore()
else:
    raise SystemExit("usage: planner_capacity_snapshot.py [--dump|--restore]")
