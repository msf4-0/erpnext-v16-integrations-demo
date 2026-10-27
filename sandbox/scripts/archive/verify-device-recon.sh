#!/usr/bin/env bash
# Pre-authoring reconnaissance for the "Device" doctype: confirm v16 has no
# doctype named Device (which would collide with a new app-provided one).
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

echo "== apps present =="
ls apps/

echo "-- any core doctype dir matching device* --"
find apps/frappe apps/erpnext -type d -iname 'device*' 2>/dev/null | head

echo "-- any DocType json whose name is exactly Device --"
grep -rl '"name": "Device"' apps/frappe apps/erpnext 2>/dev/null | head

echo "-- DocTypes in DB whose name contains Device --"
bench --site frontend execute frappe.client.get_list --kwargs \
  "{'doctype':'DocType','filters':{'name':['like','%Device%']},'fields':['name','module'],'limit_page_length':20}"

echo "-- Modules in DB (check for an existing robotics-ish module) --"
bench --site frontend execute frappe.client.get_list --kwargs \
  "{'doctype':'Module Def','fields':['name','app_name'],'limit_page_length':100}"
