#!/usr/bin/env bash
# Exercise the Car controller end-to-end (not just "it imports"): create/update
# records, confirm the derived service summary, and probe the edge cases
# deliberately. Runs against the live v16 site.
#
# PATH NOTE (same trap as robotics_lab): v16 uses the NESTED layout —
#   apps/car_tracker/car_tracker/                <- python package (hooks.py)
#   apps/car_tracker/car_tracker/car_tracker/    <- MODULE dir (doctype/)
# so the importable helper `car_tracker._diag` must live in the PACKAGE dir
# (apps/car_tracker/car_tracker/_diag/), NOT beside the doctypes.
#
# DB client is `mariadb`, not `mysql` (mariadb:11.8).
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

APP_DIR=apps/car_tracker/car_tracker
DB_NAME=$(env/bin/python -c "import json;print(json.load(open('sites/$SITE/site_config.json'))['db_name'])")

echo "== permissions for Car =="
mariadb -h db -u root -padmin "$DB_NAME" -e \
  "SELECT role, permlevel, \`read\` AS r, \`write\` AS w, \`create\` AS c, \`delete\` AS d FROM \`tabDocPerm\` WHERE parent='Car' AND parenttype='DocType';" 2>/dev/null

mkdir -p "$APP_DIR/_diag"
cat > "$APP_DIR/_diag/__init__.py" <<'PYEOF'
PYEOF
cat > "$APP_DIR/_diag/run.py" <<'PYEOF'
import frappe
from frappe.utils import add_days, add_months, today

Counter = {"n": 0}


def _car(**kwargs):
	Counter["n"] += 1
	values = {
		"doctype": "Car",
		"license_plate": f"DIAG-{Counter['n']:04d}",
		"make": "Toyota",
		"model": "Corolla",
		"status": "Active",
		"last_recorded_mileage": 0,
	}
	values.update(kwargs)
	return frappe.get_doc(values)


def create():
	frappe.set_user("Administrator")
	if frappe.db.exists("Car", {"license_plate": "DIAG-MAIN"}):
		frappe.delete_doc("Car", frappe.db.get_value("Car", {"license_plate": "DIAG-MAIN"}, "name"), force=1)
	doc = _car(
		license_plate="DIAG-MAIN",
		make="Toyota",
		model="Hilux",
		manufacture_year=2020,
		vin="DIAGVIN0000000001",
		body_type="Pickup",
		fuel_type="Diesel",
		colour="White",
		last_recorded_mileage=12000,
		mileage_recorded_on=add_days(today(), -2),
		oil_change_interval_months=6,
		oil_change_interval_km=5000,
		service_interval_months=12,
		service_interval_km=10000,
	)
	doc.append("service_records", {
		"service_type": "Oil Change",
		"service_date": add_days(today(), -200),
		"odometer": 8000,
		"vendor": "Garage A",
		"cost": 150.50,
	})
	doc.append("service_records", {
		"service_type": "Brake Service",
		"service_date": add_days(today(), -30),
		"odometer": 11000,
		"vendor": "Garage B",
		"cost": 320,
	})
	doc.insert(ignore_permissions=True)
	print("CREATED:", doc.name)
	for f in (
		"last_oil_change_date", "last_oil_change_mileage",
		"next_oil_change_due_date", "next_oil_change_due_mileage",
		"last_maintenance_date", "last_maintenance_mileage",
		"next_maintenance_due_date", "next_maintenance_due_mileage",
		"service_records_count", "total_maintenance_cost", "service_status",
	):
		print(f"  {f}: {doc.get(f)}")


def edges():
	frappe.set_user("Administrator")
	results = []

	def record(label, got, want):
		ok = "OK" if str(got) == str(want) else "MISMATCH"
		results.append((label, got, want, ok))

	# 1. no service history -> blank summary, status No Service History
	d = _car(last_recorded_mileage=0)
	d.insert(ignore_permissions=True)
	record("no_history_last_oil", d.last_oil_change_date, None)
	record("no_history_last_maint", d.last_maintenance_date, None)
	record("no_history_count", d.service_records_count, 0)
	record("no_history_status", d.service_status, "No Service History")
	d.delete()

	# 2. oil fields use the NEWEST OIL row, not the newest row overall
	d = _car(last_recorded_mileage=20000, oil_change_interval_months=12)
	d.append("service_records", {"service_type": "Oil Change", "service_date": add_days(today(), -200), "odometer": 15000})
	d.append("service_records", {"service_type": "Brake Service", "service_date": add_days(today(), -10), "odometer": 19500})
	d.insert(ignore_permissions=True)
	record("oil_from_oil_row_date", str(d.last_oil_change_date), str(add_days(today(), -200)))
	record("oil_from_oil_row_km", d.last_oil_change_mileage, 15000)
	record("maint_is_newest_any_km", d.last_maintenance_mileage, 19500)
	d.delete()

	# 3. next-due maths
	last = add_days(today(), -30)
	d = _car(last_recorded_mileage=12000, oil_change_interval_months=6, oil_change_interval_km=5000)
	d.append("service_records", {"service_type": "Oil Change", "service_date": last, "odometer": 10000})
	d.insert(ignore_permissions=True)
	record("next_oil_date", str(d.next_oil_change_due_date), str(add_months(last, 6)))
	record("next_oil_km", d.next_oil_change_due_mileage, 15000)
	d.delete()

	# 4. zero intervals -> no next-due, no crash
	d = _car(last_recorded_mileage=12000, oil_change_interval_months=0, oil_change_interval_km=0,
			 service_interval_months=0, service_interval_km=0)
	d.append("service_records", {"service_type": "Oil Change", "service_date": add_days(today(), -30), "odometer": 10000})
	d.insert(ignore_permissions=True)
	record("zero_interval_date", d.next_oil_change_due_date, None)
	record("zero_interval_km", d.next_oil_change_due_mileage, 0)
	d.delete()

	# 5. cost totals + blank cost = 0
	d = _car(last_recorded_mileage=30000)
	d.append("service_records", {"service_type": "Oil Change", "service_date": add_days(today(), -300), "odometer": 20000, "cost": 150.50})
	d.append("service_records", {"service_type": "Brake Service", "service_date": add_days(today(), -100), "odometer": 28000, "cost": 320})
	d.append("service_records", {"service_type": "Inspection", "service_date": add_days(today(), -50), "odometer": 29000})
	d.insert(ignore_permissions=True)
	record("total_cost", d.total_maintenance_cost, 470.5)
	d.delete()

	# 6. same-date tie -> higher odometer wins
	same = add_days(today(), -5)
	d = _car(last_recorded_mileage=9000)
	d.append("service_records", {"service_type": "Oil Change", "service_date": same, "odometer": 8000})
	d.append("service_records", {"service_type": "Oil Change", "service_date": same, "odometer": 8500})
	d.insert(ignore_permissions=True)
	record("same_date_tiebreak", d.last_oil_change_mileage, 8500)
	d.delete()

	# 7. future service date REJECTED
	try:
		d = _car(last_recorded_mileage=1000)
		d.append("service_records", {"service_type": "Oil Change", "service_date": add_days(today(), 1), "odometer": 1000})
		d.insert(ignore_permissions=True)
		record("future_date", "NO ERROR - BUG", "rejected")
		d.delete()
	except frappe.ValidationError:
		record("future_date", "rejected", "rejected")

	# 8. negative recorded mileage REJECTED
	try:
		_car(last_recorded_mileage=-5).insert(ignore_permissions=True)
		record("negative_mileage", "NO ERROR - BUG", "rejected")
	except frappe.NonNegativeError:
		record("negative_mileage", "rejected", "rejected")

	# 9. negative service odometer REJECTED
	try:
		d = _car(last_recorded_mileage=1000)
		d.append("service_records", {"service_type": "Oil Change", "service_date": today(), "odometer": -1})
		d.insert(ignore_permissions=True)
		record("negative_odometer", "NO ERROR - BUG", "rejected")
		d.delete()
	except frappe.NonNegativeError:
		record("negative_odometer", "rejected", "rejected")

	# 10. duplicate plate REJECTED
	a = _car(license_plate="DIAG-DUPE")
	a.insert(ignore_permissions=True)
	try:
		_car(license_plate="DIAG-DUPE").insert(ignore_permissions=True)
		record("duplicate_plate", "NO ERROR - BUG", "rejected")
	except frappe.UniqueValidationError:
		record("duplicate_plate", "rejected", "rejected")
	a.delete()

	# 11. spoof read-only summary -> recomputed
	d = _car(last_recorded_mileage=12000)
	d.append("service_records", {"service_type": "Oil Change", "service_date": add_days(today(), -10), "odometer": 12000})
	d.last_oil_change_mileage = 999999
	d.service_records_count = 999
	d.insert(ignore_permissions=True)
	record("spoof_last_oil_km", d.last_oil_change_mileage, 12000)
	record("spoof_count", d.service_records_count, 1)
	d.delete()

	# 12. update recomputes; remove newest rolls back
	d = _car(last_recorded_mileage=12000)
	d.append("service_records", {"service_type": "Oil Change", "service_date": add_days(today(), -200), "odometer": 8000})
	d.insert(ignore_permissions=True)
	d.append("service_records", {"service_type": "Oil Change", "service_date": add_days(today(), -5), "odometer": 12000})
	d.save(ignore_permissions=True)
	record("update_recalc", d.last_oil_change_mileage, 12000)
	d.service_records = d.service_records[:-1]
	d.save(ignore_permissions=True)
	record("remove_rolls_back", d.last_oil_change_mileage, 8000)
	d.delete()

	# 13. status: Overdue by date
	d = _car(last_recorded_mileage=1000, service_interval_months=12, service_interval_km=100000)
	d.append("service_records", {"service_type": "General Maintenance", "service_date": add_days(today(), -400), "odometer": 1000})
	d.insert(ignore_permissions=True)
	record("status_overdue_date", d.service_status, "Overdue")
	d.delete()

	# 14. status: Overdue by mileage
	d = _car(last_recorded_mileage=20000, service_interval_months=120, service_interval_km=10000)
	d.append("service_records", {"service_type": "General Maintenance", "service_date": today(), "odometer": 10000})
	d.insert(ignore_permissions=True)
	record("status_overdue_km", d.service_status, "Overdue")
	d.delete()

	# 15. status: Due Soon (inside 30 days)
	d = _car(last_recorded_mileage=1000, service_interval_months=12, service_interval_km=100000)
	d.append("service_records", {"service_type": "General Maintenance", "service_date": add_days(today(), -350), "odometer": 1000})
	d.insert(ignore_permissions=True)
	record("status_due_soon", d.service_status, "Due Soon")
	d.delete()

	# 16. status: OK
	d = _car(last_recorded_mileage=1000, service_interval_months=12, service_interval_km=100000)
	d.append("service_records", {"service_type": "General Maintenance", "service_date": add_days(today(), -10), "odometer": 1000})
	d.insert(ignore_permissions=True)
	record("status_ok", d.service_status, "OK")
	d.delete()

	# 17. advisory warning (does not overwrite), and silence at/below
	d = _car(last_recorded_mileage=5000)
	d.append("service_records", {"service_type": "Oil Change", "service_date": today(), "odometer": 9000})
	frappe.local.message_log = []
	d.run_method("validate")
	warned = any("Last Recorded Mileage" in (m.get("message") or "") for m in (frappe.local.message_log or []))
	frappe.local.message_log = []
	record("advisory_warns", warned, True)
	d.insert(ignore_permissions=True)
	record("advisory_no_overwrite", d.last_recorded_mileage, 5000)
	d.delete()

	d = _car(last_recorded_mileage=9000)
	d.append("service_records", {"service_type": "Oil Change", "service_date": today(), "odometer": 9000})
	frappe.local.message_log = []
	d.run_method("validate")
	silent = not any("Last Recorded Mileage" in (m.get("message") or "") for m in (frappe.local.message_log or []))
	frappe.local.message_log = []
	record("advisory_silent_at_equal", silent, True)

	# 18. blank mileage/interval coerced, no crash
	d = frappe.get_doc({
		"doctype": "Car",
		"license_plate": "DIAG-BLANK",
		"make": "X",
		"model": "Y",
		"status": "Active",
		"last_recorded_mileage": None,
		"oil_change_interval_months": None,
		"oil_change_interval_km": None,
	})
	d.insert(ignore_permissions=True)
	record("blank_coerced", d.last_recorded_mileage, 0)
	d.delete()

	print("=== EDGE CASE RESULTS ===")
	fails = 0
	for label, got, want, ok in results:
		print(f"{label:26} | got={got!s:22} | want={want!s:22} | {ok}")
		if ok != "OK":
			fails += 1
	print(f"FAILURES: {fails}")
PYEOF

bench --site "$SITE" execute car_tracker._diag.run.create
echo
echo "== EDGE CASES =="
bench --site "$SITE" execute car_tracker._diag.run.edges

# Clean up the diag helper so it never ships with the app.
rm -rf "$APP_DIR/_diag"
