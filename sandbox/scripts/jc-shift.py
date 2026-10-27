#!/usr/bin/env python3
"""Print (and optionally re-window) one Job Card's capacity blocks.

Same endpoint the UI drag uses, so this is also the clean way to put a demo Job
Card back after a UI test.

    # read only
    JC=PO-JOB00002 ./env/bin/python /tmp/scripts/jc-shift.py
    # move it to an explicit window (server shifts every block by the delta)
    JC=PO-JOB00002 START="2026-10-27 14:10:00" END="2026-10-29 16:10:00" \
        ./env/bin/python /tmp/scripts/jc-shift.py
"""
import os
import sys

import frappe
import requests

SITE = os.environ.get("SITE_NAME", "frontend")
PLANNER = os.environ.get("PLANNER_URL", "http://scheduler:3000")
JC = os.environ.get("JC")
START = os.environ.get("START")
END = os.environ.get("END")

os.chdir("/home/frappe/frappe-bench/sites")
frappe.init(site=SITE, sites_path=".")
frappe.connect()
frappe.set_user("Administrator")

if not JC:
    print("usage: JC=<job card> [START='YYYY-MM-DD HH:MM:SS' END='...'] jc-shift.py")
    sys.exit(2)

child = frappe.get_meta("Job Card").get_field("scheduled_time_logs").options


def show(label):
    rows = frappe.get_all(
        child, filters={"parent": JC}, fields=["name", "from_time", "to_time", "time_in_mins"], order_by="idx asc"
    )
    print("%s JC=%s blocks=%d expected=%s..%s" % (
        label, JC, len(rows),
        frappe.db.get_value("Job Card", JC, "expected_start_date"),
        frappe.db.get_value("Job Card", JC, "expected_end_date"),
    ))
    for row in rows:
        print("   %s %s -> %s (%s min)" % (row.name, row.from_time, row.to_time, row.time_in_mins))
    return rows


show("BEFORE")

if START and END:
    payload = {
        "type": "jobcard",
        "docName": JC,
        "start": START,
        "end": END,
        "workOrderId": frappe.db.get_value("Job Card", JC, "work_order"),
    }
    response = requests.put("%s/api/schedule/sync-reschedule" % PLANNER, json=payload, timeout=180)
    print("PUT %s -> %s %s" % (payload["start"], response.status_code, response.text[:160]))
    frappe.db.commit()
    show("AFTER")

frappe.destroy()
