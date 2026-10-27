#!/usr/bin/env bash
# Exercise the Device controller end-to-end (not just "it imports"):
# create/update records, confirm the computed fields, and probe the edge cases
# deliberately. Runs against the live v16 site.
#
# PATH NOTE (cost me a run): the app uses the v16 NESTED layout:
#   apps/robotics_lab/robotics_lab/            <- python package (hooks.py)
#   apps/robotics_lab/robotics_lab/robotics_lab/  <- MODULE dir (doctype/)
# so the importable helper `robotics_lab._diag` must live in the PACKAGE dir
# (apps/robotics_lab/robotics_lab/_diag/), NOT beside the doctypes.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

APP_DIR=apps/robotics_lab/robotics_lab
DB_NAME=$(python3 -c "import json;print(json.load(open('sites/$SITE/site_config.json'))['db_name'])")

echo "== permissions for Device =="
mysql -h db -u root -padmin "$DB_NAME" -e \
  "SELECT role, permlevel, \`read\` AS r, \`write\` AS w, \`create\` AS c, \`delete\` AS d FROM \`tabDocPerm\` WHERE parent='Device' AND parenttype='DocType';" 2>/dev/null

echo
echo "== create a Device and check computed consumption (500W x 12h = 6.0 kWh/day) =="
mkdir -p "$APP_DIR/_diag"
cat > "$APP_DIR/_diag/__init__.py" <<'PYEOF'
PYEOF
cat > "$APP_DIR/_diag/run.py" <<'PYEOF'
import frappe


def create():
	frappe.set_user("Administrator")
	if frappe.db.exists("Device", {"device_name": "UR5e Arm"}):
		frappe.delete_doc(
			"Device",
			frappe.db.get_value("Device", {"device_name": "UR5e Arm"}, "name"),
			force=1,
		)
	doc = frappe.get_doc(
		{
			"doctype": "Device",
			"device_name": "UR5e Arm",
			"device_type": "Robot",
			"status": "Active",
			"location": "Lab A",
			"manufacturer": "Universal Robots",
			"model_number": "UR5e",
			"serial_number": "SN-UR5E-001",
			"power_rating_w": 500,
			"standby_power_w": 25,
			"voltage_v": 230,
			"current_a": 2.2,
			"power_source": "Mains",
			"daily_operating_hours": 12,
		}
	).insert(ignore_permissions=True)
	print("CREATED:", doc.name)
	print("daily_kwh:", doc.estimated_daily_consumption_kwh)
	print("annual_kwh:", doc.estimated_annual_consumption_kwh)


def edges():
	frappe.set_user("Administrator")
	results = []

	def fresh(**kw):
		base = {
			"doctype": "Device",
			"device_name": "Edge Device",
			"device_type": "Light",
			"status": "Idle",
		}
		base.update(kw)
		return frappe.get_doc(base)

	# 1. zero rating
	d = fresh(power_rating_w=0, daily_operating_hours=10)
	d.insert(ignore_permissions=True)
	results.append(("zero_rating", d.estimated_daily_consumption_kwh, d.estimated_annual_consumption_kwh))
	d.delete()

	# 2. blank/None power fields
	d = fresh()
	d.insert(ignore_permissions=True)
	results.append(("blank_fields", d.estimated_daily_consumption_kwh, d.estimated_annual_consumption_kwh))
	d.delete()

	# 3. exactly 24h (boundary, allowed)
	d = fresh(power_rating_w=100, daily_operating_hours=24)
	d.insert(ignore_permissions=True)
	results.append(("24h_boundary", d.estimated_daily_consumption_kwh, d.estimated_annual_consumption_kwh))
	d.delete()

	# 4. over 24h (must be REJECTED)
	try:
		fresh(power_rating_w=100, daily_operating_hours=25).insert(ignore_permissions=True)
		results.append(("over_24h", "NO ERROR - BUG", None))
	except frappe.ValidationError as e:
		results.append(("over_24h", "rejected OK", str(e)[:60]))

	# 5. negative hours (must be REJECTED)
	try:
		fresh(power_rating_w=100, daily_operating_hours=-1).insert(ignore_permissions=True)
		results.append(("negative_hours", "NO ERROR - BUG", None))
	except Exception as e:
		results.append(("negative_hours", "rejected OK", type(e).__name__))

	# 6. negative power rating (non_negative property must block)
	try:
		d = fresh(power_rating_w=-5, daily_operating_hours=5)
		d.insert(ignore_permissions=True)
		results.append(("negative_rating", "NO ERROR - BUG", d.estimated_daily_consumption_kwh))
		d.delete()
	except Exception as e:
		results.append(("negative_rating", "rejected OK", type(e).__name__))

	# 7. very large value
	d = fresh(power_rating_w=1000000, daily_operating_hours=24)
	d.insert(ignore_permissions=True)
	results.append(("huge_value", d.estimated_daily_consumption_kwh, d.estimated_annual_consumption_kwh))
	d.delete()

	# 8. read-only enforcement: try to spoof the computed field
	d = fresh(power_rating_w=500, daily_operating_hours=12)
	d.estimated_daily_consumption_kwh = 9999
	d.insert(ignore_permissions=True)
	results.append(("spoof_attempt", d.estimated_daily_consumption_kwh, "(want 6.0, not 9999)"))
	d.delete()

	# 9. update path recalculates
	d = fresh(power_rating_w=500, daily_operating_hours=12)
	d.insert(ignore_permissions=True)
	before = d.estimated_daily_consumption_kwh
	d.daily_operating_hours = 6
	d.save(ignore_permissions=True)
	results.append(("update_recalc", before, d.estimated_daily_consumption_kwh))
	d.delete()

	# 10. duplicate serial_number (unique) must be rejected
	a = fresh(device_name="Dup A", serial_number="SN-DUP-1")
	a.insert(ignore_permissions=True)
	try:
		b = fresh(device_name="Dup B", serial_number="SN-DUP-1")
		b.insert(ignore_permissions=True)
		results.append(("dup_serial", "NO ERROR - BUG", None))
		b.delete()
	except Exception as e:
		results.append(("dup_serial", "rejected OK", type(e).__name__))
	a.delete()

	print("=== EDGE CASE RESULTS ===")
	for label, a_, b_ in results:
		print(f"{label:18} | {a_} | {b_}")
PYEOF

bench --site "$SITE" execute robotics_lab._diag.run.create

echo
echo "== EDGE CASES =="
bench --site "$SITE" execute robotics_lab._diag.run.edges
