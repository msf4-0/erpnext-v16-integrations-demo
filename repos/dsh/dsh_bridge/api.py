"""HTTP surface of the DSH bridge.

Exactly three whitelisted endpoints:

  handle_chat        conversation: prompt -> intent -> validated tool -> card
  execute_action     explicit tool call (buttons, confirmation, integrations)
  handle_a2ui_action back-compat alias kept for the existing page contract

All business logic lives in actions.py and is reachable only through
registry.ACTIONS.
"""

from __future__ import annotations

import frappe
from frappe import _

from . import actions as _actions  # noqa: F401  (registers ACTIONS on import)
from .actions import default_company
from .registry import get_action, validate_args
from .router import match_intent


@frappe.whitelist(allow_guest=False, methods=["POST"])
def handle_chat():
    payload = _payload()
    prompt = (payload.get("prompt") or "").strip()
    company = payload.get("company") or default_company()

    if not prompt:
        return _error(_("Prompt parameter is required."), 417)

    try:
        routed = match_intent(prompt)
        if not routed:
            return {
                "status": "success",
                "reply": (
                    "Echo (no orchestrator configured): '{0}'. "
                    "Try 'inventory' or 'create order 2 x SKU008 for Grant Plastics Ltd.'"
                ).format(prompt),
                "a2ui_card": None,
            }

        name, args = routed
        spec = get_action(name)

        # The page sends its active company. Inject it only when the tool
        # accepts one and the value really exists (the page falls back to the
        # literal "Default Company").
        if (
            "company" in spec["params"]
            and not args.get("company")
            and company
            and frappe.db.exists("Company", company)
        ):
            args["company"] = company

        return _card(spec, _execute(spec, args))

    except frappe.PermissionError as exc:
        return _error(exc, 403)
    except frappe.ValidationError as exc:
        return _error(exc, 417)
    except Exception:
        frappe.log_error(frappe.get_traceback(), "DSH Bridge Chat Error")
        return _error(_("Backend error while handling the chat prompt. Check Error Log."), 500)


@frappe.whitelist(allow_guest=False, methods=["POST"])
def execute_action():
    """POST {"action": "create_sales_order", "args": {...}}"""
    payload = _payload()
    try:
        spec = get_action(payload.get("action"))
        return _card(spec, _execute(spec, payload.get("args") or {}))
    except frappe.PermissionError as exc:
        return _error(exc, 403)
    except frappe.ValidationError as exc:
        return _error(exc, 417)
    except Exception:
        frappe.log_error(frappe.get_traceback(), "DSH Bridge Action Error")
        return _error(_("An internal error occurred while processing the action."), 500)


@frappe.whitelist(allow_guest=False)
def handle_a2ui_action():
    """Legacy contract: {"action": ..., ...flat args} -> {status, message, data}."""
    payload = _payload()
    name = payload.get("action")
    args = payload.get("args")
    if args is None:
        args = {key: value for key, value in payload.items() if key != "action"}

    try:
        spec = get_action(name)
        result = _execute(spec, args)
        return {"status": "success", "message": spec["label"], "data": result}
    except frappe.PermissionError as exc:
        return _error(exc, 403)
    except frappe.ValidationError as exc:
        return _error(exc, 417)
    except Exception:
        frappe.log_error(frappe.get_traceback(), "DSH Bridge Action Error")
        return _error(_("An internal error occurred while processing the action."), 500)


# --------------------------------------------------------------------------- #
# internals
# --------------------------------------------------------------------------- #
def _execute(spec, args):
    clean = validate_args(spec["params"], args)
    _check_permission(spec)
    return spec["handler"](**clean)


def _check_permission(spec):
    doctype = spec.get("doctype")
    if not doctype:
        return
    ptype = spec.get("perm_type") or "read"
    if not frappe.has_permission(doctype, ptype):
        frappe.throw(
            _("Not permitted to {0} {1}").format(ptype, doctype),
            frappe.PermissionError,
        )


def _card(spec, result):
    result = dict(result or {})
    card = {
        "status": "success",
        "reply": result.pop("message", None) or spec["label"],
    }
    if spec.get("card_type"):
        card["card_type"] = spec["card_type"]
        if "columns" in result:
            card["columns"] = result.pop("columns")
        if "rows" in result:
            card["data"] = result.pop("rows")
    card.update(result)
    return card


def _error(message, status):
    frappe.local.response["http_status_code"] = status
    text = str(message)
    return {"status": "error", "reply": text, "message": text}


def _payload():
    """JSON body when present, else form_dict (bench/RQ has no request)."""
    request = getattr(frappe.local, "request", None)
    if request is None:
        return dict(frappe.form_dict or {})

    raw = getattr(request, "data", None)
    content_type = (getattr(request, "content_type", "") or "").lower()
    if raw and "json" in content_type:
        return frappe.parse_json(raw.decode("utf-8")) or {}

    return dict(frappe.form_dict or {})
