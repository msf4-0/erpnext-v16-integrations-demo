"""A2UI surface builders for the DSH bridge.

A *surface* is the JSON the chat page renders: a flat list of components that
reference values in ``dataModel`` by path, so layout and data stay separate.

This module is pure standard library — no ``frappe`` import — so it can be
exercised from the host with plain ``python3`` and from the bench unchanged.
It is the Python twin of ``packages/a2ui-plugin/src/builders.ts``; the two must
emit the same shapes, which the shared fixtures under
``packages/a2ui-plugin/tests/fixtures`` guard.

Component vocabulary (kept in sync with ``a2ui-renderer/src/catalog.tsx``):

    Card      {child}                        rounded container
    Column    {children:{explicitList:[id]}} vertical stack
    Row       {children:{explicitList:[id]}} horizontal group
    Text      {text:{path}|{literalString}, usageHint?}
    Table     {columns:[{key,label,align?}], rows:{path}}
    Badge     {text:{path}|{literalString}, tone?}
    Divider   {}
    Link      {text, href}
    Button    {child, action:{name, context?, "x-erpnext":{args,confirm_required}}}

``x-erpnext`` is our extension: A2UI's own action ``context`` is string-only,
so structured arguments (numbers, dates) and the confirmation flag ride there.
"""

from __future__ import annotations

import uuid

PROTOCOL = "a2ui/0.9"


# --------------------------------------------------------------------------- #
# primitives
# --------------------------------------------------------------------------- #
def surface_id():
    return "a2ui-{0}".format(uuid.uuid4())


def _node(node_id, name, props=None):
    return {"id": node_id, "component": {name: props or {}}}


def _surface(components, data_model):
    return {
        "surfaceId": surface_id(),
        "protocol": PROTOCOL,
        "components": components,
        "dataModel": data_model,
    }


def _text(path_or_literal, usage_hint=None):
    """Text props: a dataModel path (leading '/') or an inline literal."""
    props = {"text": {"path": path_or_literal}} if path_or_literal.startswith("/") \
        else {"text": {"literalString": path_or_literal}}
    if usage_hint:
        props["usageHint"] = usage_hint
    return props


def _context(values):
    """A2UI action context: string-only key/value pairs."""
    return [
        {"key": key, "value": {"literalString": "" if value is None else str(value)}}
        for key, value in values.items()
    ]


def _action(name, args=None, confirm_required=False, context=None, token=None):
    spec = {"name": name}
    if context:
        spec["context"] = _context(context)
    if args is not None or confirm_required or token:
        spec["x-erpnext"] = {
            "args": args or {},
            "confirm_required": bool(confirm_required),
        }
        if token:
            spec["x-erpnext"]["token"] = token
    return spec


def _button(button_id, label, action_name, args=None, confirm_required=False, context=None, token=None):
    """A button plus its label child; returns the two nodes in render order."""
    return [
        _node(button_id, "Button", {
            "child": "{0}-label".format(button_id),
            "action": _action(action_name, args, confirm_required, context, token),
        }),
        _node("{0}-label".format(button_id), "Text", _text(label)),
    ]


# --------------------------------------------------------------------------- #
# builders
# --------------------------------------------------------------------------- #
def build_text_card(title, body, actions=None):
    """A titled card with one paragraph and optional buttons.

    ``actions`` items: ``{name, label, args?, confirm_required?}``.
    """
    children = ["title", "body"]
    components = [
        _node("root", "Card", {"child": "col"}),
        _node("title", "Text", _text(title, "h3")),
        _node("body", "Text", _text(body)),
    ]
    for index, action in enumerate(actions or []):
        button_id = "action-{0}".format(index)
        children.append(button_id)
        components.extend(_button(
            button_id,
            action.get("label") or action["name"],
            action["name"],
            action.get("args"),
            action.get("confirm_required", False),
            action.get("context"),
        ))
    components.insert(1, _node("col", "Column", {"children": {"explicitList": children}}))
    return _surface(components, {"title": title, "body": body})


def build_inventory_table(title, rows, columns=None):
    """A card holding a stock table. ``rows`` are dicts keyed by column key."""
    columns = columns or [
        {"key": "item_code", "label": "Item"},
        {"key": "item_name", "label": "Name"},
        {"key": "qty", "label": "Qty", "align": "right"},
        {"key": "status", "label": "Status"},
    ]
    normalized = [
        {column["key"]: row.get(column["key"]) for column in columns}
        for row in rows or []
    ]
    components = [
        _node("root", "Card", {"child": "col"}),
        _node("col", "Column", {"children": {"explicitList": ["title", "table", "count"]}}),
        _node("title", "Text", _text(title, "h3")),
        _node("table", "Table", {"columns": columns, "rows": {"path": "/rows"}}),
        _node("count", "Text", _text("{0} row(s)".format(len(normalized)), "caption")),
    ]
    return _surface(components, {"title": title, "rows": normalized})


def build_order_preview(title, fields, action):
    """A draft-order preview: field list plus the confirm button.

    ``fields`` is an ordered list of ``(label, value)``; ``action`` is
    ``{name, label, args, confirm_required, token?}``. Nothing is written here —
    the button posts to ``execute_action`` with a server-issued token.
    """
    rows = [{"label": label, "value": "" if value is None else str(value)} for label, value in fields]
    children = ["title", "fields"]
    components = [
        _node("root", "Card", {"child": "col"}),
        _node("col", "Column", {"children": {"explicitList": children}}),
        _node("title", "Text", _text(title, "h3")),
        _node("fields", "Table", {
            "columns": [{"key": "label", "label": "Field"}, {"key": "value", "label": "Value"}],
            "rows": {"path": "/fields"},
        }),
    ]
    children.append("action-0")
    components.extend(_button(
        "action-0",
        action.get("label") or action["name"],
        action["name"],
        action.get("args"),
        action.get("confirm_required", True),
        token=action.get("token"),
    ))
    return _surface(components, {"title": title, "fields": rows})

def build_success_card(title, fields, badge=None, link=None):
    """A 'done' card: optional status badge, a field list, optional link.

    ``fields`` is an ordered list of ``(label, value)``. ``link`` is
    ``(label, href)`` and the href is always emitted as a literal — see the
    note below on why it must not go through ``_text``.
    """
    rows = [{"label": label, "value": "" if value is None else str(value)} for label, value in fields]

    children = ["title"]
    nodes = [_node("title", "Text", _text(title, "h3"))]

    if badge:
        children.append("badge")
        nodes.append(_node("badge", "Badge", {"text": {"literalString": badge}}))

    children.append("fields")
    nodes.append(_node("fields", "Table", {
        "columns": [{"key": "label", "label": "Field"}, {"key": "value", "label": "Value"}],
        "rows": {"path": "/fields"},
    }))

    if link:
        children.append("link")
        # NOT _text(): hrefs start with '/', which _text() would read as a
        # dataModel path and resolve to nothing. Force a literal.
        nodes.append(_node("link", "Link", {
            "text": {"literalString": link[0]},
            "href": {"literalString": link[1]},
        }))

    components = [
        _node("root", "Card", {"child": "col"}),
        _node("col", "Column", {"children": {"explicitList": children}}),
    ] + nodes
    return _surface(components, {"title": title, "badge": badge or "", "fields": rows})

def build_error_card(message):
    components = [
        _node("root", "Card", {"child": "col"}),
        _node("col", "Column", {"children": {"explicitList": ["title", "body"]}}),
        _node("title", "Text", _text("Something went wrong", "h3")),
        _node("body", "Text", _text(message)),
    ]
    return _surface(components, {"title": "Something went wrong", "body": message})
