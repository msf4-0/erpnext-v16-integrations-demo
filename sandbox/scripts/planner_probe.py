#!/usr/bin/env python3
"""Read-only probe of the running ERPNEXT-AI-FIX site.

Prints the facts the production planner integration depends on: ERPNext version,
installed apps, manufacturing master data, and the writability of the Job Card
schedule fields the drag-and-drop has to update.

    env/bin/python /tmp/planner_probe.py
"""
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")

frappe.init(site=SITE, sites_path=".")
frappe.connect()
frappe.set_user("Administrator")

import erpnext  # noqa: E402


def show(label, value):
	print("%-34s %s" % (label, value))


print("=" * 72)
show("site", SITE)
show("frappe.__version__", frappe.__version__)
show("erpnext.__version__", erpnext.__version__)
show("installed apps", ", ".join(frappe.get_installed_apps()))
print("=" * 72)

for dt in [
	"Company",
	"Item",
	"BOM",
	"Workstation",
	"Operation",
	"Work Order",
	"Job Card",
	"Warehouse",
	"UOM",
	"Item Group",
	"Sales Order",
]:
	try:
		show("count %s" % dt, frappe.db.count(dt))
	except Exception as exc:  # noqa: BLE001
		show("count %s" % dt, "ERR %s" % exc)

print("=" * 72)
show("companies", [d.name for d in frappe.get_all("Company", fields=["name"])])
show("workstations", [(d.name, d.workstation_type) for d in frappe.get_all("Workstation", fields=["name", "workstation_type"], limit=10)])
show(
	"work orders",
	[(d.name, d.status, str(d.planned_start_date)) for d in frappe.get_all("Work Order", fields=["name", "status", "planned_start_date"], limit=5)],
)
show(
	"job cards",
	[(d.name, d.status, d.workstation) for d in frappe.get_all("Job Card", fields=["name", "status", "workstation"], limit=5)],
)

print("=" * 72)
ms = frappe.get_doc("Manufacturing Settings")
show("disable_capacity_planning", ms.get("disable_capacity_planning"))
show("capacity_planning_for_days", ms.get("capacity_planning_for_days"))

print("  --- Job Card / Work Order field writability ---")
jc_meta = frappe.get_meta("Job Card")
for fname in ["scheduled_time_logs", "time_logs", "workstation", "status"]:
	f = jc_meta.get_field(fname)
	show(
		"JobCard.%s" % fname,
		"allow_on_submit=%s read_only=%s fieldtype=%s" % (f.allow_on_submit, f.read_only, f.fieldtype) if f else "MISSING",
	)
wo_meta = frappe.get_meta("Work Order")
for fname in ["planned_start_date", "planned_end_date", "workstation"]:
	f = wo_meta.get_field(fname)
	show(
		"WorkOrder.%s" % fname,
		"allow_on_submit=%s read_only=%s fieldtype=%s" % (f.allow_on_submit, f.read_only, f.fieldtype) if f else "MISSING",
	)
op_meta = frappe.get_meta("Work Order Operation")
for fname in ["planned_start_time", "planned_end_time", "workstation"]:
	f = op_meta.get_field(fname)
	show(
		"WOOperation.%s" % fname,
		"allow_on_submit=%s read_only=%s fieldtype=%s" % (f.allow_on_submit, f.read_only, f.fieldtype) if f else "MISSING",
	)

print("=" * 72)
show("planner-needed doctypes exist", {
	dt: bool(frappe.db.exists("DocType", dt))
	for dt in ["Work Order", "Job Card", "Workstation", "Item", "BOM", "Virtual Work Order"]
})
print("DONE")
