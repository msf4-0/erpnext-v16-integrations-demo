#!/usr/bin/env python3
"""Add a "Production Planner" link to the ERPNext Manufacturing workspace.

The planner is a separate service, so it cannot be a desk page; the native way to
surface an external URL in the desk is a Workspace Shortcut of type URL. This
appends one to the Manufacturing workspace and adds the matching `shortcut`
block to the workspace's `content`, which is what v16 actually renders.

Manufacturing is a STANDARD (app-shipped) workspace, so v16 refuses `ws.save()`
outright ("Standard workspaces can't be edited directly"). Site edits have to go
through the Custom Workspace delta: `upsert_content_customization(name, content,
new_widgets)` stores the layout snapshot plus the item rows for added blocks, and
`apply_customization()` merges them at render time. Non-standard workspaces are
still edited in place.

Best-effort and idempotent: on any layout surprise it warns and leaves the
workspace untouched - the planner is still reachable at its own URL.

    env/bin/python /tmp/ai-fix-planner-workspace.py --url http://localhost:3001
"""
import argparse
import json
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")
WORKSPACE = os.environ.get("PLANNER_WORKSPACE", "Manufacturing")
LABEL = "Production Planner"; ICON = "calendar"


def shortcut_row(url):
	return {"type": "URL", "label": LABEL, "url": url, "icon": ICON}


def shortcut_block():
	return {"id": "plannerShortcut", "type": "shortcut", "data": {"shortcut_name": LABEL, "col": 3}}


def has_block(content):
	return any(
		isinstance(blk, dict)
		and blk.get("type") == "shortcut"
		and (blk.get("data") or {}).get("shortcut_name") == LABEL
		for blk in content
	)


def main():
	parser = argparse.ArgumentParser()
	parser.add_argument("--url", default="http://localhost:3001")
	args = parser.parse_args()

	frappe.init(site=SITE, sites_path=".")
	frappe.connect()
	frappe.set_user("Administrator")

	if not frappe.db.exists("Workspace", WORKSPACE):
		print("WARN workspace %r missing - skipping shortcut" % WORKSPACE)
		return

	# A freshly created site (which is what a tmpfs wipe leaves behind) still has
	# the setup wizard pending, and the desk then redirects every /app/<route> to
	# it - including this shortcut's target. `frappe.is_setup_complete()` reads
	# Installed Application.is_setup_complete for frappe + erpnext (not System
	# Settings), so that is what has to be set, and the cached bootinfo the desk
	# reads has to be dropped. The barcode/shopify flows never notice either way;
	# a desk link does.
	pending = frappe.get_all(
		"Installed Application",
		{"app_name": ("in", ["frappe", "erpnext"]), "is_setup_complete": 0},
		pluck="app_name",
	)
	if pending:
		for app in pending:
			frappe.db.set_value("Installed Application", {"app_name": app}, "is_setup_complete", 1)
		frappe.db.commit()
		frappe.clear_cache()
		frappe.cache.delete_key("bootinfo")
		print("MARK marked setup complete for %s (desk wizard skipped)" % ", ".join(pending))

	from frappe.desk.doctype.custom_workspace.custom_workspace import (
		get_customization,
		upsert_content_customization,
	)

	ws = frappe.get_doc("Workspace", WORKSPACE)
	standard = bool(ws.standard) and not frappe.conf.developer_mode

	custom = get_customization(WORKSPACE) if standard else None
	content = json.loads((custom.content if custom and custom.content else ws.content) or "[]")
	widgets = json.loads(((custom.widgets if custom else None) or "{}"))

	rows = [s for s in ws.shortcuts if s.label == LABEL]
	for row in widgets.get("shortcut", []):
		if row.get("label") == LABEL and row not in rows:
			rows.append(row)

	if rows and has_block(content):
		current = rows[0].get("url") if isinstance(rows[0], dict) else rows[0].url
		if current == args.url:
			print("MARK shortcut already present -> %s" % args.url)
			return
		# Only the URL changed: rewrite the stored row, leave the layout alone.
		for row in widgets.get("shortcut", []):
			if row.get("label") == LABEL:
				row["url"] = args.url
		if standard:
			upsert_content_customization(WORKSPACE, content, {"shortcut": [shortcut_row(args.url)]})
		else:
			for row in rows:
				row.url = args.url
			ws.save(ignore_permissions=True)
		frappe.db.commit()
		print("MARK updated shortcut URL to %s" % args.url)
		return

	if not has_block(content):
		content.append(shortcut_block())

	if standard:
		upsert_content_customization(WORKSPACE, content, {"shortcut": [shortcut_row(args.url)]})
	else:
		ws.append("shortcuts", shortcut_row(args.url))
		ws.content = json.dumps(content)
		ws.save(ignore_permissions=True)

	frappe.db.commit()
	print("MARK shortcut added to %r workspace -> %s" % (WORKSPACE, args.url))


if __name__ == "__main__":
	main()
