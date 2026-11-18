#!/usr/bin/env python3
"""Replay the planner's exact ERPNext REST calls with its API token.

This is the pre-flight check: every query below is a query the Node backend
issues (see server.js), so a 200 here means the planner will see real data.

    PLANNER_API_KEY=... PLANNER_API_SECRET=... env/bin/python /tmp/planner_rest_probe.py
"""
import json
import os
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("ERPNEXT_URL", "http://localhost:8000")
KEY = os.environ["PLANNER_API_KEY"]
SECRET = os.environ["PLANNER_API_SECRET"]


def call(doctype, fields=None, filters=None, limit=None):
	params = {}
	if fields:
		params["fields"] = json.dumps(fields)
	if filters:
		params["filters"] = json.dumps(filters)
	if limit:
		params["limit_page_length"] = limit
	url = "%s/api/resource/%s?%s" % (BASE, urllib.parse.quote(doctype), urllib.parse.urlencode(params))
	req = urllib.request.Request(url, headers={"Authorization": "token %s:%s" % (KEY, SECRET)})
	try:
		with urllib.request.urlopen(req, timeout=30) as resp:
			return resp.status, json.loads(resp.read().decode())
	except urllib.error.HTTPError as exc:
		return exc.code, exc.read().decode()[:400]


print("--- Workstation (planner filters disabled=0) ---")
code, body = call(
	"Workstation",
	fields=["name", "workstation_name", "workstation_type", "status"],
	filters=[["disabled", "=", 0]],
	limit=500,
)
print(code, json.dumps(body)[:500] if isinstance(body, dict) else body)

print("--- Work Order ---")
code, body = call(
	"Work Order",
	fields=[
		"name",
		"production_item",
		"item_name",
		"qty",
		"status",
		"planned_start_date",
		"planned_end_date",
		"docstatus",
	],
	filters=[["docstatus", "!=", 2]],
	limit=500,
)
if code == 200:
	rows = body.get("data", [])
	print(code, "rows=%d" % len(rows))
	print(json.dumps(rows[:3], indent=1)[:700])
else:
	print(code, body)

print("--- Job Card ---")
code, body = call(
	"Job Card",
	fields=[
		"name",
		"work_order",
		"operation",
		"workstation",
		"status",
		"for_quantity",
		"expected_start_date",
		"expected_end_date",
		"production_item",
		"item_name",
	],
	filters=[["docstatus", "!=", 2]],
	limit=500,
)
if code == 200:
	rows = body.get("data", [])
	print(code, "rows=%d" % len(rows))
	print(json.dumps(rows[:2], indent=1)[:600])
else:
	print(code, body)

print("--- single Work Order (planner fetches full doc for details) ---")
code, body = call("Work Order", filters=[["docstatus", "=", 1]], limit=1)
name = body["data"][0]["name"] if code == 200 and body.get("data") else None
print("picked", name)
if name:
	with urllib.request.urlopen(
		urllib.request.Request(
			"%s/api/resource/Work%20Order/%s" % (BASE, urllib.parse.quote(name)),
			headers={"Authorization": "token %s:%s" % (KEY, SECRET)},
		),
		timeout=30,
	) as resp:
		doc = json.loads(resp.read().decode())["data"]
	print(
		"  operations=%s"
		% [(o.get("operation"), o.get("workstation"), o.get("planned_start_time"), o.get("planned_end_time")) for o in doc.get("operations", [])]
	)
	print("  planned_start_date=%s planned_end_date=%s" % (doc.get("planned_start_date"), doc.get("planned_end_date")))
	print("  job cards:", frappe_free := len([1]))  # placeholder keeps output shape stable
