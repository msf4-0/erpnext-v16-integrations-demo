#!/usr/bin/env python3
"""Put one Job Card capacity block back to an explicit window (demo-data repair).

    SITE_NAME=frontend ./env/bin/python /tmp/scripts/fix-block.py <block-row-name> \
        "2026-10-26 08:00:00" "2026-10-26 17:00:00"
"""
import os
import sys

import frappe

SITE = os.environ.get("SITE_NAME", "frontend")
os.chdir("/home/frappe/frappe-bench/sites")
frappe.init(site=SITE, sites_path=".")
frappe.connect()
frappe.set_user("Administrator")

row = os.environ.get("BLOCK_ROW") or (sys.argv[1] if len(sys.argv) > 1 else None)
start = os.environ.get("BLOCK_FROM") or (sys.argv[2] if len(sys.argv) > 2 else None)
end = os.environ.get("BLOCK_TO") or (sys.argv[3] if len(sys.argv) > 3 else None)
if not (row and start and end):
    print("usage: BLOCK_ROW=<row> BLOCK_FROM='YYYY-MM-DD HH:MM:SS' BLOCK_TO='...' fix-block.py")
    sys.exit(2)
child = frappe.get_meta("Job Card").get_field("scheduled_time_logs").options
before = frappe.db.get_value(child, row, ["from_time", "to_time", "parent"], as_dict=True)
frappe.db.set_value(child, row, {"from_time": start, "to_time": end}, update_modified=False)
frappe.db.commit()
print("FIXED %s %s -> %s  (was %s -> %s, parent %s)" % (row, start, end, before.from_time, before.to_time, before.parent))
frappe.destroy()
