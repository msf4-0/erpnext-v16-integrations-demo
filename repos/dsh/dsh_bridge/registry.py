"""Static action registry (the DSH bridge's tool catalogue).

Every command is a plain handler registered here. Action names are resolved
*only* through ACTIONS, never via getattr/import from request data, so the
browser cannot invoke arbitrary Python callables.
"""

from __future__ import annotations

import frappe
from frappe import _
from frappe.utils import getdate

ACTIONS: dict[str, dict] = {}


def action(
    name,
    *,
    label,
    params,
    doctype=None,
    perm_type="create",
    mutating=True,
    card_type=None,
):
    """Register a handler as a callable tool.

    params: {key: {"type": "str"|"int"|"float"|"date"|"bool",
                   "required": bool, "default": Any, "min": number, "max": number}}
    doctype/perm_type: permission checked before the handler runs (None = skip).
    card_type: frontend card to render (e.g. "inventory_table").
    """
    if not isinstance(params, dict):
        raise ValueError(f"params for action {name} must be a dict")

    def decorator(fn):
        if name in ACTIONS:
            raise ValueError(f"Duplicate DSH action: {name}")
        ACTIONS[name] = {
            "name": name,
            "label": label,
            "params": params,
            "doctype": doctype,
            "perm_type": perm_type,
            "mutating": mutating,
            "card_type": card_type,
            "handler": fn,
        }
        return fn

    return decorator


def get_action(name):
    from . import actions as _actions  # noqa: F401  (populate ACTIONS on first use)

    spec = ACTIONS.get(name or "")
    if not spec:
        frappe.throw(_("Unknown action: {0}").format(name), frappe.ValidationError)
    return spec


def validate_args(params, args):
    """Coerce and validate a tool payload. Unknown keys are rejected, so a
    typo (or a hallucinated argument) never silently changes behaviour."""
    if args is None:
        args = {}
    if not isinstance(args, dict):
        frappe.throw(_("'args' must be an object"), frappe.ValidationError)

    clean = {}
    for key, value in args.items():
        if key not in params:
            frappe.throw(_("Unknown parameter: {0}").format(key), frappe.ValidationError)
        clean[key] = _coerce(key, value, params[key])

    for key, spec in params.items():
        clean.setdefault(key, spec.get("default"))
        if spec.get("required") and clean.get(key) in (None, ""):
            frappe.throw(_("Missing required parameter: {0}").format(key), frappe.ValidationError)

    return clean


def _coerce(key, value, spec):
    if value is None or value == "":
        return None

    kind = spec.get("type", "str")
    try:
        if kind == "str":
            value = str(value).strip()
        elif kind == "int":
            value = int(value)
        elif kind == "float":
            value = float(value)
        elif kind == "date":
            value = getdate(value)
        elif kind == "bool":
            value = value if isinstance(value, bool) else str(value).lower() in ("1", "true", "yes", "on")
        else:
            frappe.throw(_("Unsupported parameter type: {0}").format(kind), frappe.ValidationError)
    except (TypeError, ValueError):
        frappe.throw(_("Parameter {0} must be a valid {1}").format(key, kind), frappe.ValidationError)

    if kind in ("int", "float"):
        if "min" in spec and value < spec["min"]:
            frappe.throw(_("Parameter {0} must be >= {1}").format(key, spec["min"]), frappe.ValidationError)
        if "max" in spec and value > spec["max"]:
            frappe.throw(_("Parameter {0} must be <= {1}").format(key, spec["max"]), frappe.ValidationError)

    return value
