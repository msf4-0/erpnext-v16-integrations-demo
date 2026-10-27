#!/usr/bin/env python3
"""Seed manufacturing demo data for the drag-and-drop production planner.

A site created by `bench new-site --install-app erpnext` plus the Shopify sync
has Items but NO Workstations, Operations, BOMs, Work Orders or Job Cards - so
the planner renders an empty board. This creates the minimum data set that makes
the board meaningful:

    Workstations (4)  ->  Operations  ->  Items (FG + raw)  ->  BOMs with
    operations  ->  submitted Work Orders  ->  auto-created Job Cards

Work Orders are spread across the coming weeks so the month/week grids have
content on more than one day.

Idempotent: masters are ensured by name; Work Order creation is skipped once any
Work Order exists (pass --force-orders to add another batch on top).

    env/bin/python /tmp/seed_planner_demo.py [--force-orders]
"""
import os
import sys
from datetime import timedelta

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")
COMPANY = os.environ.get("PLANNER_COMPANY", "SHRDC")
FORCE_ORDERS = "--force-orders" in sys.argv
RESET_ORDERS = "--reset-orders" in sys.argv

WORKSTATIONS = [
	# (name, hour_rate, working_hours[(start, end)], capacity)
	("WS-CUTTING", 25.0, [("08:00:00", "17:00:00")], 1),
	("WS-CNC", 45.0, [("08:00:00", "17:00:00")], 2),
	("WS-ASSEMBLY", 30.0, [("08:00:00", "17:00:00")], 1),
	("WS-PACKING", 15.0, [("08:00:00", "17:00:00")], 1),
]

# (item_code, item_name, [(operation, workstation, minutes), ...])
PRODUCTS = [
	("PLN-BRACKET", "Planner Steel Bracket", [("Cutting", "WS-CUTTING", 45), ("Assembly", "WS-ASSEMBLY", 60)]),
	("PLN-SHAFT", "Planner Drive Shaft", [("CNC Machining", "WS-CNC", 90), ("Assembly", "WS-ASSEMBLY", 30)]),
	("PLN-HOUSING", "Planner Pump Housing", [("CNC Machining", "WS-CNC", 120), ("Packing", "WS-PACKING", 20)]),
	("PLN-COUPLING", "Planner Coupling", [("Cutting", "WS-CUTTING", 30), ("CNC Machining", "WS-CNC", 60)]),
	("PLN-FRAME", "Planner Mounting Frame", [("Cutting", "WS-CUTTING", 75), ("Assembly", "WS-ASSEMBLY", 90)]),
	("PLN-KIT", "Planner Assembly Kit", [("Assembly", "WS-ASSEMBLY", 45), ("Packing", "WS-PACKING", 30)]),
]

RAW_ITEMS = [
	("PLN-RM-STEEL", "Planner Raw Steel Sheet"),
	("PLN-RM-BAR", "Planner Raw Alloy Bar"),
	("PLN-RM-BOLT", "Planner Raw Bolt Set"),
	("PLN-RM-SEAL", "Planner Raw Seal Ring"),
]

# Work Orders per product, as an offset in days from today.
ORDER_PLAN = [
	("PLN-BRACKET", [(0, 20), (3, 15)]),
	("PLN-SHAFT", [(1, 12), (4, 12)]),
	("PLN-HOUSING", [(2, 8), (7, 8)]),
	("PLN-COUPLING", [(2, 30), (8, 25)]),
	("PLN-FRAME", [(5, 10), (9, 10)]),
	("PLN-KIT", [(6, 40), (10, 40)]),
]


def log(msg):
	print("MARK %s" % msg)


def summary(**kw):
	import json

	print("SUMMARY " + json.dumps(kw, default=str))


def first_uom():
	if frappe.db.exists("UOM", "Nos"):
		return "Nos"
	name = frappe.db.get_value("UOM", {}, "name")
	if name:
		return name
	frappe.get_doc({"doctype": "UOM", "uom_name": "Nos", "enabled": 1}).insert(ignore_permissions=True)
	return "Nos"


def ensure_item(item_code, item_name, uom, is_fg):
	if frappe.db.exists("Item", item_code):
		return item_code

	item_group = "Products" if frappe.db.exists("Item Group", "Products") else frappe.db.get_value("Item Group", {}, "name")
	item = frappe.get_doc(
		{
			"doctype": "Item",
			"item_code": item_code,
			"item_name": item_name,
			"item_group": item_group,
			"stock_uom": uom,
			"is_stock_item": 1,
			"is_sales_item": 1 if is_fg else 0,
			"is_purchase_item": 0 if is_fg else 1,
			"description": "Planner demo item",
		}
	)
	item.insert(ignore_permissions=True)
	log("item created: %s" % item_code)
	return item_code


def ensure_workstation(name, hour_rate, hours, capacity):
	if frappe.db.exists("Workstation", name):
		return name
	doc = frappe.get_doc(
		{
			"doctype": "Workstation",
			"workstation_name": name,
			"production_capacity": capacity,
			"hour_rate": hour_rate,
			"working_hours": [
				{"start_time": start, "end_time": end, "enabled": 1} for start, end in hours
			],
		}
	)
	doc.insert(ignore_permissions=True)
	log("workstation created: %s" % name)
	return name


def ensure_operation(name, workstation):
	if frappe.db.exists("Operation", name):
		return name
	doc = frappe.get_doc(
		{
			"doctype": "Operation",
			"name": name,
			"workstation": workstation,
			"description": "Planner demo operation",
		}
	)
	doc.insert(ignore_permissions=True)
	log("operation created: %s" % name)
	return name


def ensure_bom(item_code, operations, raw_items, uom):
	existing = frappe.db.get_value("BOM", {"item": item_code, "docstatus": 1}, "name")
	if existing:
		return existing

	currency = frappe.db.get_value("Company", COMPANY, "default_currency") or "MYR"
	bom = frappe.get_doc(
		{
			"doctype": "BOM",
			"item": item_code,
			"company": COMPANY,
			"quantity": 1,
			"uom": uom,
			"conversion_rate": 1,
			"currency": currency,
			"with_operations": 1,
			"items": [{"item_code": rm, "qty": 1, "uom": uom, "stock_uom": uom} for rm in raw_items],
			"operations": [
				{
					"operation": op,
					"workstation": ws,
					"time_in_mins": mins,
					"sequence_id": idx + 1,
				}
				for idx, (op, ws, mins) in enumerate(operations)
			],
		}
	)
	bom.insert(ignore_permissions=True)
	bom.submit()
	log("bom submitted: %s (%.0f cost)" % (bom.name, bom.total_cost or 0))
	return bom.name


def warehouse_defaults():
	"""Company warehouse defaults on ERPNext v16.

	The fields are `default_fg_warehouse` / `default_wip_warehouse` on Company
	(there is no `default_finished_good_warehouse`), and Manufacturing Settings
	carries no warehouse fields at all in v16.
	"""
	company = frappe.get_doc("Company", COMPANY)
	fg = company.get("default_fg_warehouse") or frappe.db.get_value(
		"Warehouse", {"warehouse_name": "Finished Goods", "company": COMPANY}, "name"
	)
	wip = company.get("default_wip_warehouse") or frappe.db.get_value(
		"Warehouse", {"warehouse_name": "Work In Progress", "company": COMPANY}, "name"
	)
	source = company.get("default_warehouse")
	return fg, wip, source


def create_work_order(item_code, bom_no, qty, days_ahead, uom, fg_wh, wip_wh, src_wh=None):
	from frappe.utils import now_datetime

	start_dt = now_datetime().replace(hour=8, minute=0, second=0, microsecond=0) + timedelta(days=days_ahead)
	doc = {
		"doctype": "Work Order",
		"production_item": item_code,
		"bom_no": bom_no,
		"qty": qty,
		"company": COMPANY,
		"stock_uom": uom,
		"planned_start_date": start_dt,
		"skip_transfer": 0,
	}
	if fg_wh:
		doc["fg_warehouse"] = fg_wh
	if wip_wh:
		doc["wip_warehouse"] = wip_wh
	if src_wh:
		doc["source_warehouse"] = src_wh

	wo = frappe.get_doc(doc)
	# ERPNext does NOT populate operations from the BOM during validate() — the
	# desk form calls the whitelisted `set_work_order_ops` when a BOM is picked.
	# A server-side Work Order must do the same, or submitting it creates no Job
	# Cards and leaves planned_end_date empty.
	wo.set_work_order_operations()
	wo.insert(ignore_permissions=True)
	wo.submit()
	jc_count = frappe.db.count("Job Card", {"work_order": wo.name})
	log(
		"work order submitted: %s (%s x%s, plan %s -> %s, %s ops, %s job cards)"
		% (
			wo.name,
			item_code,
			qty,
			wo.planned_start_date,
			wo.planned_end_date,
			len(wo.operations),
			jc_count,
		)
	)
	return wo


def reset_work_orders():
	"""Cancel + delete every Work Order (and its Job Cards) so a re-seed is clean."""
	removed = 0
	for jc in frappe.get_all("Job Card", fields=["name", "docstatus"]):
		doc = frappe.get_doc("Job Card", jc.name)
		if doc.docstatus == 1:
			doc.cancel()
		frappe.delete_doc("Job Card", jc.name, force=1, ignore_permissions=True)
		removed += 1
	for wo in frappe.get_all("Work Order", fields=["name", "docstatus"]):
		doc = frappe.get_doc("Work Order", wo.name)
		if doc.docstatus == 1:
			doc.cancel()
		frappe.delete_doc("Work Order", wo.name, force=1, ignore_permissions=True)
		removed += 1
	frappe.db.commit()
	log("reset: removed %s job cards + work orders" % removed)


def main():
	frappe.init(site=SITE, sites_path=".")
	frappe.connect()
	frappe.set_user("Administrator")

	if not frappe.db.exists("Company", COMPANY):
		raise SystemExit("ERROR: company %r does not exist on site %r - run bootstrap_masters.py first" % (COMPANY, SITE))

	uom = first_uom()
	log("uom: %s" % uom)

	for name, hour_rate, hours, capacity in WORKSTATIONS:
		ensure_workstation(name, hour_rate, hours, capacity)

	op_names = {}
	# One pass over every (product, operation) pair: the first workstation seen
	# for a name wins, and ensure_operation is idempotent for the rest.
	for _code, _name, ops in PRODUCTS:
		for op, ws, _mins in ops:
			if op not in op_names:
				op_names[op] = ensure_operation(op, ws)

	for code, name in RAW_ITEMS:
		ensure_item(code, name, uom, is_fg=False)

	for code, name, _ops in PRODUCTS:
		ensure_item(code, name, uom, is_fg=True)

	bom_map = {}
	raw_codes = [c for c, _n in RAW_ITEMS]
	for idx, (code, _name, ops) in enumerate(PRODUCTS):
		# every product consumes two raw items, rotated so BOMs are not identical
		consumed = [raw_codes[idx % len(raw_codes)], raw_codes[(idx + 1) % len(raw_codes)]]
		bom_map[code] = ensure_bom(code, ops, consumed, uom)

	if RESET_ORDERS:
		reset_work_orders()

	frappe.db.commit()

	if frappe.db.count("Work Order") and not FORCE_ORDERS:
		log("Work Orders already exist - skipping order creation (use --force-orders to add more)")
	else:
		fg_wh, wip_wh, src_wh = warehouse_defaults()
		log("warehouses: fg=%s wip=%s source=%s" % (fg_wh, wip_wh, src_wh))
		created = 0
		for code, plan in ORDER_PLAN:
			for days_ahead, qty in plan:
				try:
					create_work_order(code, bom_map[code], qty, days_ahead, uom, fg_wh, wip_wh, src_wh)
					created += 1
				except Exception as exc:  # noqa: BLE001
					log("FAILED work order for %s: %s" % (code, exc))
					frappe.db.rollback()
		frappe.db.commit()

	summary(
		workstations=frappe.db.count("Workstation"),
		operations=frappe.db.count("Operation"),
		boms=frappe.db.count("BOM", {"docstatus": 1}),
		items=frappe.db.count("Item"),
		work_orders=frappe.db.count("Work Order"),
		job_cards=frappe.db.count("Job Card"),
		job_cards_with_schedule=frappe.db.count("Job Card Scheduled Time"),
		wo_dates=[
			(str(d.planned_start_date), str(d.planned_end_date), d.status)
			for d in frappe.get_all(
				"Work Order", fields=["planned_start_date", "planned_end_date", "status"], limit=4, order_by="planned_start_date asc"
			)
		],
	)
	print("DONE")


if __name__ == "__main__":
	main()
