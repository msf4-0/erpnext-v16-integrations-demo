"""Deterministic stand-in for the DSH orchestrator.

A real deployment sends the registry's action metadata to an LLM as tool
definitions and receives {"action": ..., "args": {...}}. This module produces
the exact same shape with regexes, so replacing the mock only means rewriting
match_intent() - the dispatcher, validation and hydration stay untouched.
"""

from __future__ import annotations

import re

import frappe
from frappe.utils import add_days, today

ORDER = re.compile(
    r"\b(create|new|raise|make|place|add)\b[\s\S]*\b(order|sales\s*order|so)\b", re.I
)
STOCK = re.compile(r"\b(stock|inventory|on[-\s]?hand|availability)\b", re.I)
ITEM_CODE = re.compile(r"\b([A-Z]{2,}-[A-Z0-9]+(?:-[A-Z0-9]+)*|SKU\d+)\b")
QTY_UNIT = re.compile(r"\b(\d+(?:\.\d+)?)\s*(?:pcs|pc|units?|nos|x)\b", re.I)
QTY_AFTER = re.compile(r"\bqty\s*[:=]?\s*(\d+(?:\.\d+)?)", re.I)


def match_intent(prompt):
    """Return (action_name, args) or None."""
    text = (prompt or "").strip()
    if not text:
        return None
    if ORDER.search(text):
        return "create_sales_order", _order_args(text)
    if STOCK.search(text):
        return "get_stock_levels", {}
    return None


def _order_args(text):
    args = {}
    item = _match_item(text)
    if item:
        args["item_code"] = item
    qty = _match_qty(text)
    if qty:
        args["qty"] = qty
    customer = _match_customer(text)
    if customer:
        args["customer"] = customer

    # --- demo fallbacks -----------------------------------------------------
    # A real orchestrator asks for the missing fields (or renders a confirm
    # card) instead of guessing. These keep the demo usable with plain
    # "create order".
    args.setdefault("qty", 1)
    args.setdefault("delivery_date", add_days(today(), 7))
    args.setdefault("customer", _first_customer())
    args.setdefault("item_code", _first_stocked_item())
    return args


def _match_qty(text):
    for pattern in (QTY_UNIT, QTY_AFTER):
        match = pattern.search(text)
        if match:
            return float(match.group(1))
    return None


def _match_item(text):
    match = ITEM_CODE.search(text)
    if match and frappe.db.exists("Item", match.group(1)):
        return match.group(1)

    lowered = text.lower()
    for name in frappe.get_all(
        "Item", filters={"disabled": 0}, pluck="name", limit_page_length=0
    ):
        if name.lower() in lowered:
            return name
    return None


def _match_customer(text):
    lowered = text.lower()
    best = None
    for name in frappe.get_all(
        "Customer", filters={"disabled": 0}, pluck="name", limit_page_length=0
    ):
        stem = name.split(" ")[0].lower()
        if name.lower() in lowered or (len(stem) >= 4 and stem in lowered):
            if not best or len(name) > len(best):
                best = name
    return best


def _first_customer():
    return frappe.db.get_value("Customer", {"disabled": 0}, "name")


def _first_stocked_item():
    row = frappe.db.sql(
        "SELECT item_code FROM `tabBin` WHERE actual_qty > 0 ORDER BY actual_qty DESC LIMIT 1"
    )
    return row[0][0] if row else None
