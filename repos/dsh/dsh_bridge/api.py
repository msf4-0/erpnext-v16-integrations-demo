"""HTTP surface of the DSH bridge.

Exactly three whitelisted endpoints:

  handle_chat        conversation: prompt -> intent -> validated tool -> card
  execute_action     explicit tool call (buttons, confirmation, integrations)
  handle_a2ui_action back-compat alias kept for the existing page contract

All business logic lives in actions.py and is reachable only through
registry.ACTIONS.
"""

from __future__ import annotations

import time
import uuid

import frappe
from frappe import _

from . import actions as _actions  # noqa: F401  (registers ACTIONS on import)
from . import a2ui
from .actions import default_company
from .registry import get_action, validate_args
from .router import match_intent


@frappe.whitelist(allow_guest=False, methods=["POST"])
def handle_chat():
    started = time.monotonic()
    trace_id = str(uuid.uuid4())
    payload = _payload()
    prompt = (payload.get("prompt") or "").strip()
    company = payload.get("company") or default_company()

    if not prompt:
        return _finish(_error(_("Prompt parameter is required."), 417), started, trace_id)

    try:
        routed = match_intent(prompt)
        if not routed:
            reply = (
                "Echo (no orchestrator configured): '{0}'. "
                "Try 'inventory' or 'create order 2 x SKU008 for Grant Plastics Ltd.'"
            ).format(prompt)
            return _finish(
                {"status": "success", "reply": reply, "a2ui_card": None},
                started,
                trace_id,
            )

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

        clean = _prepare(spec, args)
        if spec["mutating"]:
            return _finish(_preview(spec, clean), started, trace_id)
        return _finish(_card(spec, spec["handler"](**clean)), started, trace_id)

    except frappe.PermissionError as exc:
        return _finish(_error(exc, 403), started, trace_id)
    except frappe.ValidationError as exc:
        return _finish(_error(exc, 417), started, trace_id)
    except Exception:
        frappe.log_error(frappe.get_traceback(), "DSH Bridge Chat Error")
        return _finish(
            _error(_("Backend error while handling the chat prompt. Check Error Log."), 500),
            started,
            trace_id,
        )


@frappe.whitelist(allow_guest=False, methods=["POST"])
def execute_action():
    """POST {"confirm_token": "..."} (button) or {"action": "...", "args": {...}} (direct)."""
    payload = _payload()
    try:
        token = payload.get("confirm_token")
        if token:
            pending = _consume_token(token)
            spec = get_action(pending["action"])
            return _card(spec, spec["handler"](**validate_args(spec["params"], pending["args"])))

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
def _finish(payload, started, trace_id, mode="fallback"):
    """Attach the frozen chat contract to a legacy payload.

    `ui` + `mode` + `trace_id` + `latency_ms` are the forward contract; every
    existing key (`card_type`, `columns`, `data`, `actions`) stays for the
    current page until it renders surfaces directly.
    """
    payload = dict(payload or {})
    payload["ui"] = _surface_for(payload)
    payload["mode"] = mode
    payload["trace_id"] = trace_id
    payload["latency_ms"] = int((time.monotonic() - started) * 1000)
    return payload


def _surface_for(payload):
    """Pick the card for one payload. Display-only: never raises."""
    if payload.get("status") == "error":
        return a2ui.build_error_card(payload.get("reply") or _("Backend error"))

    if payload.get("card_type") == "inventory_table":
        columns = []
        for key, label in payload.get("columns") or []:
            column = {"key": key, "label": label}
            if key in ("actual_qty", "qty", "rate", "amount"):
                column["align"] = "right"
            columns.append(column)
        return a2ui.build_inventory_table(
            payload.get("reply") or _("Inventory"),
            payload.get("data") or [],
            columns or None,
        )

    if payload.get("status") == "pending_confirmation":
        action = (payload.get("actions") or [{}])[0]
        args = action.get("args") or {}
        fields = [
            (key.replace("_", " ").capitalize(), value)
            for key, value in args.items()
            if value not in (None, "")
        ]
        return a2ui.build_order_preview(
            payload.get("reply") or action.get("label"),
            fields,
            {
                # The legacy payload names the tool `action`; the surface names it `name`.
                "name": action.get("name") or action.get("action"),
                "label": action.get("label"),
                "args": args,
                "confirm_required": True,
                "token": action.get("token"),
            },
        )

    return a2ui.build_text_card(_("DSH Assistant"), payload.get("reply") or "")


def _prepare(spec, args):
    clean = validate_args(spec["params"], args)
    _check_permission(spec)
    return clean

def _execute(spec, args):
    return spec["handler"](**_prepare(spec, args))

CONFIRM_KEY = "dsh:confirm:{0}"
CONFIRM_TTL = 300  # 5 minutes


def _preview(spec, clean):
    """Two-phase write: return an actionable card instead of executing."""
    token = frappe.generate_hash(length=20)
    frappe.cache.set_value(
        CONFIRM_KEY.format(token),
        {"action": spec["name"], "args": clean, "user": frappe.session.user},
        user=frappe.session.user,
        expires_in_sec=CONFIRM_TTL,
    )
    details = "\n".join(
        "{0}: {1}".format(key.replace("_", " ").capitalize(), value)
        for key, value in clean.items()
        if value not in (None, "")
    )
    return {
        "status": "pending_confirmation",
        "reply": "{0}?\n{1}".format(spec["label"], details),
        "card_type": "action_confirm",
        "actions": [
            {
                "label": spec["label"],
                "action": spec["name"],
                "args": clean,
                "token": token,
                "style": "primary",
            }
        ],
    }


def _consume_token(token):
    key = CONFIRM_KEY.format(token)
    pending = frappe.cache.get_value(key, user=frappe.session.user)
    if not pending:
        frappe.throw(
            _("This action expired or was already used. Run the prompt again."),
            frappe.ValidationError,
        )
    if pending.get("user") != frappe.session.user:
        frappe.throw(_("This confirmation belongs to another session."), frappe.PermissionError)
    frappe.cache.delete_value(key, user=frappe.session.user)   # one-shot
    return pending

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
