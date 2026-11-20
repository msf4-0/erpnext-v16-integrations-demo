"""Tool implementations for the DSH bridge.

Handlers are never HTTP endpoints. They are reached only through
api.handle_chat / api.execute_action, which validate arguments and enforce
permissions before calling them.
"""

from __future__ import annotations

import frappe
from frappe import _
from frappe.utils import add_days, flt, getdate, today

from .registry import action


def default_company():
    return (
        frappe.defaults.get_user_default("Company")
        or frappe.defaults.get_global_default("company")
    )


# --------------------------------------------------------------------------- #
# read tools
# --------------------------------------------------------------------------- #
@action(
    "get_stock_levels",
    label="Get stock levels",
    mutating=False,
    doctype="Bin",
    perm_type="read",
    card_type="inventory_table",
    params={
        "limit": {"type": "int", "required": False, "default": 5, "min": 1, "max": 50},
        "warehouse": {"type": "str", "required": False},
        "company": {"type": "str", "required": False},
    },
)
def get_stock_levels(limit=5, warehouse=None, company=None):
    conditions = ["b.actual_qty <> 0"]
    values = {"limit": limit}

    if warehouse:
        conditions.append("b.warehouse = %(warehouse)s")
        values["warehouse"] = warehouse
    if company:
        conditions.append("b.company = %(company)s")
        values["company"] = company

    rows = frappe.db.sql(
        """
        SELECT
            b.item_code,
            i.item_name,
            b.warehouse,
            b.actual_qty,
            b.stock_uom
        FROM `tabBin` b
        LEFT JOIN `tabItem` i ON i.name = b.item_code
        WHERE {where}
        ORDER BY b.actual_qty DESC
        LIMIT %(limit)s
        """.format(where=" AND ".join(conditions)),
        values,
        as_dict=True,
    )

    return {
        "message": "{0} item(s) with stock{1}".format(
            len(rows), " in {0}".format(company) if company else ""
        ),
        "columns": [
            ["item_code", "Item"],
            ["item_name", "Name"],
            ["warehouse", "Warehouse"],
            ["actual_qty", "Qty"],
            ["stock_uom", "UOM"],
        ],
        "rows": rows,
    }


# --------------------------------------------------------------------------- #
# write tools
# --------------------------------------------------------------------------- #
@action(
    "create_sales_order",
    label="Create Sales Order",
    doctype="Sales Order",
    perm_type="create",
    card_type="sales_order_created",
    params={
        "customer": {"type": "str", "required": True},
        "item_code": {"type": "str", "required": True},
        "qty": {"type": "float", "required": True, "min": 0.0001},
        "delivery_date": {"type": "date", "required": False},
        "warehouse": {"type": "str", "required": False},
        "rate": {"type": "float", "required": False, "min": 0},
    },
)
def create_sales_order(customer, item_code, qty, delivery_date=None, warehouse=None, rate=None):
    """Insert a DRAFT Sales Order (docstatus 0: no stock, no ledger impact)."""
    company = default_company()
    if not company:
        frappe.throw(_("No default company is configured for this user"))

    if not frappe.db.exists("Customer", customer):
        frappe.throw(_("Customer {0} does not exist").format(customer), frappe.ValidationError)

    item = frappe.db.get_value(
        "Item", item_code, ["item_name", "disabled"], as_dict=True
    )
    if not item or item.disabled:
        frappe.throw(
            _("Item {0} does not exist or is disabled").format(item_code),
            frappe.ValidationError,
        )

    delivery_date = getdate(delivery_date or add_days(today(), 7))
    if delivery_date < getdate(today()):
        frappe.throw(_("Delivery date cannot be in the past"), frappe.ValidationError)

    warehouse = _resolve_warehouse(item_code, company, warehouse)

    if rate is None:
        price_list = (
            frappe.db.get_single_value("Selling Settings", "selling_price_list")
            or "Standard Selling"
        )
        rate = flt(
            frappe.db.get_value(
                "Item Price",
                {"item_code": item_code, "price_list": price_list, "selling": 1},
                "price_list_rate",
            )
        )

    so = frappe.get_doc(
        {
            "doctype": "Sales Order",
            "customer": customer,
            "company": company,
            "transaction_date": today(),
            "delivery_date": delivery_date,
            "set_warehouse": warehouse,
            "items": [
                {
                    "item_code": item_code,
                    "qty": qty,
                    "rate": rate,
                    "warehouse": warehouse,
                    "delivery_date": delivery_date,
                }
            ],
        }
    )
    # ignore_permissions stays False: the caller already passed has_permission()
    so.insert()

    return {
        "message": (
            "Created draft Sales Order {0}: {1:g} x {2} ({3}) for {4} - total {5} {6:,.2f}"
        ).format(
            so.name,
            qty,
            item_code,
            item.item_name,
            so.customer,
            so.currency,
            so.grand_total,
        ),
        "sales_order": {
            "name": so.name,
            "customer": so.customer,
            "item_code": item_code,
            "qty": qty,
            "grand_total": so.grand_total,
            "currency": so.currency,
            "docstatus": so.docstatus,
            "route": "/app/sales-order/{0}".format(so.name),
        },
    }


@action(
    "create_test_order",
    label="Create test ToDo",
    doctype="ToDo",
    perm_type="create",
    params={},
)
def create_test_order():
    todo = frappe.get_doc(
        {
            "doctype": "ToDo",
            "description": "Created via DSH Assistant",
            "status": "Open",
        }
    )
    todo.insert()  # no explicit commit: Frappe commits the request
    return {"message": "Created ToDo {0}".format(todo.name), "todo": {"name": todo.name}}


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def _resolve_warehouse(item_code, company, warehouse=None):
    if warehouse:
        return warehouse

    warehouse = frappe.db.get_value(
        "Item Default",
        {"parent": item_code, "parenttype": "Item", "company": company},
        "default_warehouse",
    )
    if warehouse:
        return warehouse

    warehouse = frappe.db.get_value(
        "Item Default",
        {"parent": item_code, "parenttype": "Item"},
        "default_warehouse",
    )
    if warehouse:
        return warehouse

    warehouse = frappe.db.get_value(
        "Warehouse", {"company": company, "is_group": 0, "disabled": 0}, "name"
    )
    if not warehouse:
        frappe.throw(
            _("No warehouse available for company {0}").format(company),
            frappe.ValidationError,
        )
    return warehouse
