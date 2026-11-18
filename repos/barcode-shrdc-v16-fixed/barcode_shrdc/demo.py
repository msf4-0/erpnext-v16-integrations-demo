# -*- coding: utf-8 -*-
"""Small, generic manufacturing demo dataset.

This replaces the old Go-Kart / Planner assembly fixtures.  It is deliberately
industry-neutral: a light-fabrication shop making a control cabinet and an
assembly bench.  Five submitted BOMs (three finished goods and two
sub-assemblies) are enough to demonstrate multi-level manufacturing without
flooding the item master.

The functions are idempotent.  `ensure_demo_manufacturing()` is called by the
`seed_demo_manufacturing` post-model-sync patch, so a restored demo database and
a freshly provisioned site end up with exactly the same small dataset.
"""

from __future__ import annotations

import frappe
from frappe.utils import flt

ITEM_GROUP_ROOT = "All Item Groups"
UOM = "Nos"

# BOM cost basis.  "Valuation Rate" leaves every demo BOM at zero because the
# demo items never have a stock transaction, so the BOMs are priced from a
# price list instead: one Item Price per demo item, seeded from the same rate
# as the item's `standard_rate`.
PRICE_LIST_CANDIDATES = ("Standard Buying", "Standard Selling")
FALLBACK_PRICE_LIST = "Standard Buying"

# code, name, group, standard_rate
DEMO_ITEMS = (
	("RM-SHEET-01", "Cold-Rolled Steel Sheet, 1.5 mm", "Raw Material", 42.0),
	("RM-TUBE-01", "Square Steel Tube, 40 x 40 mm", "Raw Material", 28.0),
	("RM-HINGE-01", "Heavy-Duty Cabinet Hinge", "Raw Material", 6.5),
	("RM-LOCK-01", "Cam Lock with Two Keys", "Raw Material", 9.0),
	("RM-BOLT-M8-01", "M8 Hex Bolt Pack (25 pcs)", "Raw Material", 12.0),
	("RM-BOLT-M10-01", "M10 Hex Bolt Pack (10 pcs)", "Raw Material", 14.0),
	("RM-TOP-01", "Workbench Top, 1800 x 750 mm", "Raw Material", 165.0),
	("RM-PAINT-01", "Powder Coat, Graphite (kg)", "Raw Material", 18.0),
	("RM-WIRE-01", "Wiring Harness, 800 mm", "Raw Material", 7.5),
	("RM-TERMINAL-01", "DIN Terminal Block", "Raw Material", 2.2),
	("SUB-FRAME-01", "Cabinet Frame Weldment", "Sub Assemblies", 210.0),
	("SUB-WIRING-01", "Control Panel Wiring Set", "Sub Assemblies", 68.0),
	("SUB-LEGSET-01", "Workbench Leg Set", "Sub Assemblies", 145.0),
	("FG-CABINET-01", "Control Cabinet, 800 x 600 mm", "Finished Goods", 640.0),
	("FG-BENCH-01", "Assembly Workbench, 1800 mm", "Finished Goods", 520.0),
)

# parent code, [(component code, qty), ...]
DEMO_BOMS = (
	(
		"FG-CABINET-01",
		(
			("SUB-FRAME-01", 1),
			("SUB-WIRING-01", 1),
			("RM-HINGE-01", 2),
			("RM-LOCK-01", 1),
			("RM-BOLT-M8-01", 1),
			("RM-PAINT-01", 1),
		),
	),
	(
		"SUB-FRAME-01",
		(
			("RM-TUBE-01", 4),
			("RM-SHEET-01", 2),
			("RM-BOLT-M8-01", 2),
			("RM-PAINT-01", 1),
		),
	),
	(
		"SUB-WIRING-01",
		(
			("RM-WIRE-01", 2),
			("RM-TERMINAL-01", 4),
		),
	),
	(
		"FG-BENCH-01",
		(
			("SUB-LEGSET-01", 1),
			("RM-TOP-01", 1),
			("RM-BOLT-M10-01", 1),
			("RM-PAINT-01", 1),
		),
	),
	(
		"SUB-LEGSET-01",
		(
			("RM-TUBE-01", 6),
			("RM-SHEET-01", 1),
			("RM-BOLT-M10-01", 2),
		),
	),
)

# Everything created by the retired Go-Kart / Planner demo.  BOMs are removed
# first; items that are still referenced by submitted transactions are disabled
# rather than force-deleted so the cleanup can never corrupt a live site.
LEGACY_ITEM_PREFIXES = ("PLN-", "GKRT-")
LEGACY_ITEM_CODES = (
	"FRM-001",
	"WHL-001",
	"STR-001",
	"HST-001",
	"SET-001",
)


def _ensure_item_group(group_name: str, parent: str) -> None:
	if frappe.db.exists("Item Group", group_name):
		return
	frappe.get_doc(
		{
			"doctype": "Item Group",
			"item_group_name": group_name,
			"parent_item_group": parent,
			"is_group": 0,
		}
	).insert(ignore_permissions=True)


def _ensure_warehouse(company: str) -> str | None:
	warehouse = frappe.db.get_single_value("Stock Settings", "default_warehouse")
	if warehouse:
		return warehouse
	return frappe.db.get_value(
		"Warehouse",
		{"company": company, "is_group": 0, "disabled": 0},
		"name",
		order_by="creation asc",
	)


def _company() -> str:
	company = frappe.defaults.get_global_default("company") or frappe.db.get_value(
		"Company", {}, "name", order_by="creation asc"
	)
	if not company:
		raise frappe.ValidationError("No Company found; create a company before seeding demo data.")
	return company


def _legacy_item_codes() -> list[str]:
	codes = set(LEGACY_ITEM_CODES)
	for prefix in LEGACY_ITEM_PREFIXES:
		codes.update(
			frappe.get_all(
				"Item",
				filters={"item_code": ("like", f"{prefix}%")},
				pluck="item_code",
			)
		)
		# The item may already be gone while its cancelled BOM remains, so read
		# the BOM side too.
		codes.update(
			frappe.get_all(
				"BOM",
				filters={"item": ("like", f"{prefix}%")},
				pluck="item",
			)
		)
	return sorted(codes)


def _delete_bom(bom_name: str) -> None:
	bom = frappe.get_doc("BOM", bom_name)
	if bom.docstatus == 1:
		bom.cancel()
	try:
		frappe.delete_doc("BOM", bom_name, force=1, ignore_permissions=True)
	except Exception:
		# Cancelled BOMs can still be blocked by stale link rows.  They are
		# inert, so remove the BOM and its child rows directly as a last
		# resort; this only ever targets the retired demo items.
		frappe.db.delete("BOM Item", {"parent": bom_name})
		frappe.db.delete("BOM", {"name": bom_name})


def clean_legacy_demo() -> dict:
	"""Remove the old Go-Kart/Planner BOMs and items, best-effort.

	Submitted Work Orders and Job Cards that point at a retired demo item are
	cancelled and deleted first because MariaDB otherwise refuses the item
	delete.  Any item still referenced by a non-demo document is disabled, not
	removed.
	"""
	legacy_codes = _legacy_item_codes()
	removed_boms = 0
	removed_items = 0
	disabled_items = 0

	if legacy_codes:
		for wo in frappe.get_all(
			"Work Order",
			filters={"production_item": ("in", legacy_codes)},
			fields=["name", "docstatus"],
		):
			try:
				doc = frappe.get_doc("Work Order", wo.name)
				if doc.docstatus == 1:
					doc.cancel()
				if doc.docstatus != 2:
					frappe.delete_doc("Work Order", doc.name, force=1, ignore_permissions=True)
			except Exception:
				frappe.log_error(
					title="Demo cleanup: Work Order not removed",
					message=frappe.get_traceback(),
				)

		for bom in frappe.get_all(
			"BOM",
			filters={"item": ("in", legacy_codes)},
			fields=["name"],
		):
			try:
				_delete_bom(bom.name)
				removed_boms += 1
			except Exception:
				frappe.log_error(title="Demo cleanup: BOM not removed", message=frappe.get_traceback())

		# A BOM created against a sub-assembly may itself be a component of a
		# different legacy BOM; the loop above only caught BOMs keyed by the
		# legacy item.  Remove those child rows too.
		for bom in frappe.get_all(
			"BOM",
			filters={"item": ("in", legacy_codes), "docstatus": ("<", 2)},
			fields=["name"],
		):
			try:
				_delete_bom(bom.name)
				removed_boms += 1
			except Exception:
				pass

		for code in legacy_codes:
			if not frappe.db.exists("Item", code):
				continue
			try:
				frappe.delete_doc("Item", code, force=1, ignore_permissions=True)
				removed_items += 1
			except Exception:
				try:
					frappe.db.set_value("Item", code, "disabled", 1, update_modified=False)
					disabled_items += 1
				except Exception:
					frappe.log_error(title="Demo cleanup: item not removed", message=frappe.get_traceback())

	return {
		"removed_boms": removed_boms,
		"removed_items": removed_items,
		"disabled_items": disabled_items,
	}


def _ensure_items(company: str) -> None:
	for group, parent in (
		("Raw Material", ITEM_GROUP_ROOT),
		("Sub Assemblies", ITEM_GROUP_ROOT),
		("Finished Goods", ITEM_GROUP_ROOT),
	):
		_ensure_item_group(group, parent)

	for code, name, group, rate in DEMO_ITEMS:
		if frappe.db.exists("Item", code):
			continue
		frappe.get_doc(
			{
				"doctype": "Item",
				"item_code": code,
				"item_name": name,
				"item_group": group,
				"stock_uom": UOM,
				"is_stock_item": 1,
				"include_item_in_manufacturing": 1,
				"standard_rate": rate,
				"description": f"Demo master data for {company}.",
			}
		).insert(ignore_permissions=True)


def _ensure_price_lists(company: str) -> str:
	"""Ensure the buying and selling price lists exist; return the buying one.

	A restored demo database normally has "Standard Buying" and "Standard
	Selling" from the setup wizard, but a minimal restore can have only one (or
	neither).  The BOM cost basis needs a buying list, and the finished goods need
	a selling list to be quotable, so both are created on demand.
	"""
	currency = frappe.db.get_value("Company", company, "default_currency") or "USD"
	specs = (("Standard Buying", 1, 0), ("Standard Selling", 0, 1))
	for name, buying, selling in specs:
		if frappe.db.exists("Price List", name):
			continue
		frappe.get_doc(
			{
				"doctype": "Price List",
				"price_list_name": name,
				"buying": buying,
				"selling": selling,
				"enabled": 1,
				"currency": currency,
			}
		).insert(ignore_permissions=True)

	return FALLBACK_PRICE_LIST


def _ensure_item_prices() -> dict:
	"""One Item Price per demo item per existing price list, priced at standard_rate.

	Buying prices drive the BOM cost; selling prices make the finished goods
	quotable in the demo.  Idempotent: an existing row has its rate corrected
	rather than duplicated.
	"""
	created = 0
	updated = 0
	lists = [name for name in PRICE_LIST_CANDIDATES if frappe.db.exists("Price List", name)]

	for price_list in lists:
		for code, _name, _group, rate in DEMO_ITEMS:
			if not frappe.db.exists("Item", code):
				continue
			existing = frappe.get_all(
				"Item Price",
				filters={"item_code": code, "price_list": price_list},
				pluck="name",
				limit=1,
			)
			if existing:
				current = frappe.db.get_value("Item Price", existing[0], "price_list_rate")
				if flt(current) != flt(rate):
					frappe.db.set_value(
						"Item Price", existing[0], "price_list_rate", rate, update_modified=False
					)
					updated += 1
				continue
			frappe.get_doc(
				{
					"doctype": "Item Price",
					"item_code": code,
					"price_list": price_list,
					"price_list_rate": rate,
					"uom": UOM,
				}
			).insert(ignore_permissions=True)
			created += 1

	return {
		"created": created,
		"updated": updated,
		"lists": lists,
		"prices_per_list": {
			name: frappe.db.count("Item Price", {"price_list": name}) for name in lists
		},
	}


def _ensure_boms(company: str, warehouse: str | None, price_list: str | None = None) -> None:
	basis = "Price List" if price_list else "Valuation Rate"
	for parent, components in DEMO_BOMS:
		existing = frappe.get_all(
			"BOM",
			filters={"item": parent, "docstatus": 1, "is_active": 1},
			pluck="name",
			order_by="creation desc",
			limit=1,
		)
		if existing:
			bom_name = existing[0]
		else:
			bom = frappe.new_doc("BOM")
			bom.update(
				{
					"item": parent,
					"company": company,
					"quantity": 1,
					"uom": frappe.db.get_value("Item", parent, "stock_uom") or UOM,
					"is_active": 1,
					"is_default": 1,
					"with_operations": 0,
					"rm_cost_as_per": basis,
					"buying_price_list": price_list,
				}
			)
			for component, qty in components:
				uom = frappe.db.get_value("Item", component, "stock_uom") or UOM
				component_rate = flt(frappe.db.get_value("Item", component, "standard_rate"))
				bom.append(
					"items",
					{
						"item_code": component,
						"qty": qty,
						"uom": uom,
						"stock_uom": uom,
						"conversion_factor": 1,
						"source_warehouse": warehouse,
						"rate": component_rate,
						"amount": component_rate * flt(qty),
						"base_rate": component_rate,
						"base_amount": component_rate * flt(qty),
					},
				)
			bom.flags.ignore_permissions = True
			bom.insert()
			bom.submit()
			bom_name = bom.name

		# Older BOMs may have no source warehouse, which blocks material
		# requests.  Always repair that instead of creating a duplicate BOM.
		if warehouse:
			for row in frappe.get_all(
				"BOM Item",
				filters={"parent": bom_name, "source_warehouse": ("in", ["", None])},
				pluck="name",
			):
				frappe.db.set_value("BOM Item", row, "source_warehouse", warehouse, update_modified=False)

		# BOMs created before the price-list basis existed are costed from the
		# (zero) valuation rate.  Move them onto the price list and recompute, so
		# the demo never shows a BOM whose cost is 0.00.
		doc = frappe.get_doc("BOM", bom_name)
		if doc.rm_cost_as_per != basis or (price_list and doc.buying_price_list != price_list):
			doc.rm_cost_as_per = basis
			doc.buying_price_list = price_list
			if doc.docstatus == 1:
				doc.flags.ignore_validate_update_after_submit = True
			doc.flags.ignore_permissions = True
			doc.db_update()
		doc.update_cost(save=True)


def _ensure_metabase_shortcut() -> None:
	"""Expose the embedded dashboard from ERPNext's Manufacturing workspace."""
	if not frappe.db.exists("Workspace", "Manufacturing"):
		return
	workspace = frappe.get_doc("Workspace", "Manufacturing")
	if any(row.type == "URL" and row.url == "/metabase" for row in workspace.get("shortcuts", [])):
		return
	workspace.append(
		"shortcuts",
		{
			"type": "URL",
			"url": "/metabase",
			"label": "Manufacturing Analytics",
			"icon": "dashboard",
		},
	)
	workspace.save(ignore_permissions=True)


def ensure_demo_manufacturing(company: str | None = None) -> dict:
	"""Idempotently install the small generic manufacturing demo dataset."""
	company = company or _company()
	cleanup = clean_legacy_demo()
	_ensure_items(company)
	price_list = _ensure_price_lists(company)
	prices = _ensure_item_prices()
	warehouse = _ensure_warehouse(company)
	_ensure_boms(company, warehouse, price_list)
	_ensure_metabase_shortcut()
	frappe.db.commit()

	return {
		"company": company,
		"items": len(DEMO_ITEMS),
		"boms": len(DEMO_BOMS),
		"warehouse": warehouse,
		"price_list": price_list,
		"item_prices_created": prices["created"],
		"item_prices_updated": prices["updated"],
		"item_prices_per_list": prices["prices_per_list"],
		"bom_costs": {
			row.item: flt(row.total_cost)
			for row in frappe.get_all(
				"BOM",
				filters={"item": ("in", [parent for parent, _ in DEMO_BOMS]), "docstatus": 1},
				fields=["item", "total_cost"],
				order_by="item asc",
			)
		},
		**cleanup,
	}

