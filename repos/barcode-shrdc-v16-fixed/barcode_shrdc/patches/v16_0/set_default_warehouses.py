# -*- coding: utf-8 -*-
"""Give the site a default warehouse and every BOM a source warehouse.

The demo seed (`seed/frontend-database.sql.gz`) restores a database where
`Stock Settings.default_warehouse` is NULL and every `BOM Item.source_warehouse`
is NULL. In that state ERPNext cannot build a raw-material request:

  Sales Order -> Request for Raw Materials -> make_raw_material_request()
  -> Material Request rows with no warehouse -> material_request.submit()
  -> erpnext.buying.utils.validate_stock_item_warehouse()
  -> "Row #1: Warehouse is mandatory for stock Item ..."

This patch fills the blanks so a freshly seeded site works out of the box.
It is idempotent and never overwrites a warehouse that was deliberately chosen.
"""

import frappe


def execute():
	warehouse = frappe.db.get_single_value("Stock Settings", "default_warehouse")

	if not warehouse:
		company = frappe.defaults.get_global_default("company") or frappe.db.get_value(
			"Company", {}, "name"
		)
		filters = {"is_group": 0, "disabled": 0}
		if company:
			filters["company"] = company

		warehouse = frappe.db.get_value("Warehouse", filters, "name", order_by="creation asc")
		if warehouse:
			frappe.db.set_single_value("Stock Settings", "default_warehouse", warehouse)

	if not warehouse:
		# nothing to fill with - leave the site untouched
		return

	rows = frappe.get_all(
		"BOM Item",
		filters={"source_warehouse": ("in", ["", None])},
		fields=["name"],
	)
	for row in rows:
		frappe.db.set_value("BOM Item", row.name, "source_warehouse", warehouse, update_modified=False)

	if rows and frappe.db.has_column("BOM", "default_source_warehouse"):
		for bom in frappe.get_all("BOM", fields=["name", "default_source_warehouse"]):
			if not bom.default_source_warehouse:
				frappe.db.set_value(
					"BOM", bom.name, "default_source_warehouse", warehouse, update_modified=False
				)

	if rows:
		frappe.db.commit()
