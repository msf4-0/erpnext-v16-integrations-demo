#!/usr/bin/env bash
# (a) enable tests, run the app's real unit tests
# (b) determine how v16 actually serves an app-shipped doctype .js, then
#     verify OUR JS is reachable the way the desk fetches it
# (c) clean up the REST test devices created during verification
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

echo "== (a) enable tests =="
bench --site "$SITE" set-config allow_tests true

echo
echo "== run the app's unit tests (real assertion bodies) =="
bench --site "$SITE" run-tests --app robotics_lab 2>&1 | tail -40

echo
echo "== (b) how does v16 serve an app doctype .js? =="
echo "-- bundled_asset / build refs --"
grep -rn "doctype_js\|def get_js\|\.bundle\.js" apps/frappe/frappe/desk/form/load.py 2>/dev/null | head -10
echo "-- how the desk resolves a doctype's js --"
grep -rn "get_js\|js_path\|doctype.*\.js" apps/frappe/frappe/model/meta.py 2>/dev/null | head -10

echo
echo "== build assets for the app so any bundling picks up device.js =="
bench build --app robotics_lab 2>&1 | tail -8

echo
echo "== what js assets exist for robotics_lab on disk =="
find sites/assets/robotics_lab -name '*.js' 2>/dev/null | head -20

echo
echo "== (c) clean up verification devices =="
cat > apps/robotics_lab/robotics_lab/_diag/cleanup.py <<'PYEOF'
import frappe


def run():
	frappe.set_user("Administrator")
	names = frappe.get_all(
		"Device",
		filters={"device_name": ["in", ["REST Light", "Edge Device", "Dup A", "Dup B"]]},
		pluck="name",
	)
	for n in names:
		frappe.delete_doc("Device", n, force=1, ignore_permissions=True)
		print("deleted", n)
	print("remaining devices:")
	for d in frappe.get_all("Device", fields=["name", "device_name", "device_type",
											 "estimated_daily_consumption_kwh"]):
		print(" ", d)
PYEOF
bench --site "$SITE" execute robotics_lab._diag.cleanup.run
