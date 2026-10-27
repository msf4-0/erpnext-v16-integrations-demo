#!/usr/bin/env bash
# Answer precisely: does changing voltage_v / current_a affect power_rating_w
# (or the consumption estimates)? Test live, don't infer.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

echo "== 1. is the container's device.py the same one we authored? =="
DT=apps/robotics_lab/robotics_lab/robotics_lab/doctype/device
grep -n "voltage_v\|current_a\|power_rating_w" "$DT/device.py" || echo "  (no references in device.py)"
echo "-- device.js references --"
grep -n "voltage_v\|current_a\|power_rating_w" "$DT/device.js" || echo "  (none)"

echo
echo "== 2. ANY reference to voltage_v / current_a anywhere in the app? =="
grep -rn "voltage_v\|current_a" apps/robotics_lab --include=*.py --include=*.js 2>/dev/null \
  | grep -v "doctype/device/device.json" || echo "  NONE — the fields are pure storage, nothing reads them"

echo
echo "== 3. field definitions: any fetch_from / depends_on wiring? =="
python3 - <<'PY'
import json
p = "apps/robotics_lab/robotics_lab/robotics_lab/doctype/device/device.json"
d = json.load(open(p))
for f in d["fields"]:
    if f["fieldname"] in ("power_rating_w", "voltage_v", "current_a",
                          "estimated_daily_consumption_kwh",
                          "estimated_annual_consumption_kwh"):
        keys = {k: v for k, v in f.items()
                if k in ("fieldname", "read_only", "fetch_from", "depends_on",
                         "non_negative", "default")}
        print("  ", keys)
PY

echo
echo "== 4. LIVE TEST: change voltage+current, see if power/estimates move =="
mkdir -p apps/robotics_lab/robotics_lab/_diag
touch apps/robotics_lab/robotics_lab/_diag/__init__.py
cat > apps/robotics_lab/robotics_lab/_diag/volt_test.py <<'PYEOF'
import frappe


def run():
	frappe.set_user("Administrator")
	name = "DEV-VOLTTEST"
	if frappe.db.exists("Device", name):
		frappe.delete_doc("Device", name, force=1, ignore_permissions=True)

	# Start: rating 500W, voltage 230V, current 2.2A (~506 VA)
	doc = frappe.get_doc({
		"doctype": "Device",
		"device_name": "Volt Test",
		"device_type": "Robot",
		"status": "Active",
		"power_rating_w": 500,
		"voltage_v": 230,
		"current_a": 2.2,
		"daily_operating_hours": 12,
	}).insert(ignore_permissions=True)
	print("BEFORE: rating=%s  V=%s  A=%s  daily_kwh=%s  annual_kwh=%s" % (
		doc.power_rating_w, doc.voltage_v, doc.current_a,
		doc.estimated_daily_consumption_kwh, doc.estimated_annual_consumption_kwh))

	# Now change ONLY voltage and current. V x I would now imply 400*5 = 2000 W.
	doc.voltage_v = 400
	doc.current_a = 5
	doc.save(ignore_permissions=True)
	print("AFTER : rating=%s  V=%s  A=%s  daily_kwh=%s  annual_kwh=%s" % (
		doc.power_rating_w, doc.voltage_v, doc.current_a,
		doc.estimated_daily_consumption_kwh, doc.estimated_annual_consumption_kwh))

	# Reload from DB to make sure we're not seeing an in-memory illusion.
	fresh = frappe.get_doc("Device", name)
	print("RELOAD: rating=%s  V=%s  A=%s  daily_kwh=%s" % (
		fresh.power_rating_w, fresh.voltage_v, fresh.current_a,
		fresh.estimated_daily_consumption_kwh))

	expected_if_derived = 400 * 5 / 1000.0 * 12  # 24.0 kWh
	print("would-be daily_kwh if P=V*I were derived: %s" % expected_if_derived)

	frappe.delete_doc("Device", name, force=1, ignore_permissions=True)
	print("(test device removed)")
PYEOF
bench --site "$SITE" execute robotics_lab._diag.volt_test.run
