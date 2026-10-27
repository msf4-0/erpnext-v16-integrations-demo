#!/usr/bin/env python3
"""Diagnose what a Work Order drag does to each Job Card capacity block.

    cd /home/frappe/frappe-bench && SITE_NAME=frontend ./env/bin/python \
        /tmp/scripts/probe-drag.py [work_order]

Reads the WO's Job Cards + every `scheduled_time_logs` block, performs one
drag through the planner's real endpoint (PUT /api/schedule/sync-reschedule),
re-reads, prints a per-block diff, then drags it back. This is what showed that
one capacity block was disappearing instead of being shifted.
"""
import datetime
import json
import os
import sys

import frappe
import requests

SITE = os.environ.get("SITE_NAME", "frontend")
PLANNER = os.environ.get("PLANNER_URL", "http://scheduler:3000")
os.chdir("/home/frappe/frappe-bench/sites")
frappe.init(site=SITE, sites_path=".")
frappe.connect()
frappe.set_user("Administrator")

WO = sys.argv[1] if len(sys.argv) > 1 else frappe.get_all(
    "Work Order", filters={"docstatus": 1}, order_by="creation asc", pluck="name"
)[0]

child = frappe.get_meta("Job Card").get_field("scheduled_time_logs").options


def snapshot():
    state = {}
    for jc in frappe.get_all("Job Card", filters={"work_order": WO}, pluck="name"):
        doc = frappe.get_doc("Job Card", jc)
        blocks = [
            {
                "name": b.name,
                "from": str(b.from_time),
                "to": str(b.to_time),
                "mins": b.time_in_mins,
                "idx": b.idx,
            }
            for b in (doc.scheduled_time_logs or [])
        ]
        state[jc] = {
            "blocks": blocks,
            "from_time": str(doc.get("from_time")),
            "to_time": str(doc.get("to_time")),
            "expected_start": str(doc.get("expected_start_date")),
            "expected_end": str(doc.get("expected_end_date")),
            "operation": doc.operation,
            "sequence_id": doc.sequence_id,
            "total_time": doc.get("total_time_in_mins"),
        }
    return state


before = snapshot()
wo_start = frappe.db.get_value("Work Order", WO, "planned_start_date")
print("PROBE WO=%s start=%s total_blocks=%d" % (WO, wo_start, sum(len(v["blocks"]) for v in before.values())))
for jc, info in before.items():
    print(
        "PROBE before %s seq=%s op=%s blocks=%d from=%s to=%s"
        % (jc, info["sequence_id"], info["operation"], len(info["blocks"]), info["from_time"], info["to_time"])
    )
    for b in info["blocks"]:
        print("PROBE   block id=%s idx=%s %s -> %s (%s min)" % (b["name"], b["idx"], b["from"], b["to"], b["mins"]))

base = frappe.utils.get_datetime(wo_start)
new_start = base + datetime.timedelta(days=2)
payload = {
    "type": "workorder",
    "docName": WO,
    "start": new_start.strftime("%Y-%m-%d %H:%M:%S"),
    "end": (new_start + datetime.timedelta(hours=8)).strftime("%Y-%m-%d %H:%M:%S"),
    "workOrderId": WO,
}
resp = requests.put("%s/api/schedule/sync-reschedule" % PLANNER, json=payload, timeout=180)
print("PROBE drag http=%s body=%s" % (resp.status_code, resp.text[:300]))

frappe.db.commit()
frappe.db.close()
frappe.connect()
after = snapshot()
print("PROBE after total_blocks=%d (was %d)" % (sum(len(v["blocks"]) for v in after.values()), sum(len(v["blocks"]) for v in before.values())))
for jc, info in after.items():
    was = before.get(jc, {}).get("blocks", [])
    print(
        "PROBE after %s blocks=%d (was %d) from=%s to=%s"
        % (jc, len(info["blocks"]), len(was), info["from_time"], info["to_time"])
    )
    for b in info["blocks"]:
        print("PROBE   block id=%s idx=%s %s -> %s (%s min)" % (b["name"], b["idx"], b["from"], b["to"], b["mins"]))

# errors logged during the drag
for row in frappe.get_all(
    "Error Log", fields=["method", "error"], order_by="creation desc", limit_page_length=3
):
    print("PROBE errorlog %s | %s" % ((row.method or "")[:40], (row.error or "").replace("\n", " ")[:200]))

# restore
restore = dict(payload)
restore["start"] = str(wo_start)
restore["end"] = (base + datetime.timedelta(hours=8)).strftime("%Y-%m-%d %H:%M:%S")
resp = requests.put("%s/api/schedule/sync-reschedule" % PLANNER, json=restore, timeout=180)
frappe.db.commit()
frappe.db.close()
frappe.connect()
restored = snapshot()
print(
    "PROBE restored total_blocks=%d start=%s"
    % (
        sum(len(v["blocks"]) for v in restored.values()),
        frappe.db.get_value("Work Order", WO, "planned_start_date"),
    )
)
frappe.destroy()
