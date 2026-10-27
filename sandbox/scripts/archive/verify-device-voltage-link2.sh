#!/usr/bin/env bash
# Confirm from the DB (not just in-memory) whether changing voltage_v /
# current_a influences power_rating_w or the consumption estimates, and clean
# up any stray test rows.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

mkdir -p apps/robotics_lab/robotics_lab/_diag
touch apps/robotics_lab/robotics_lab/_diag/__init__.py
cat > apps/robotics_lab/robotics_lab/_diag/volt_test2.py <<'PYEOF'
import frappe


def _show(label, d):
	print("%-7s rating=%-8s V=%-6s A=%-6s | daily_kwh=%-8s annual_kwh=%s" % (
		label, d.power_rating_w, d.voltage_v, d.current_a,
		d.estimated_daily_consumption_kwh, d.estimated_annual_consumption_kwh))


def run():
	frappe.set_user("Administrator")
	frappe.db.rollback()

	# clean any leftover from the earlier broken run
	for n in frappe.get_all("Device", filters={"device_name": "Volt Test"}, pluck="name"):
		frappe.delete_doc("Device", n, force=1, ignore_permissions=True)

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
	name = doc.name
	_show("BEFORE", doc)

	# Change ONLY voltage + current (400*5 = 2000 VA).
	doc.voltage_v = 400
	doc.current_a = 5
	doc.save(ignore_permissions=True)
	print("  -> in-memory after save:")
	_show("AFTER", doc)

	# Reload from the DB to rule out an in-memory illusion.
	fresh = frappe.get_doc("Device", name)
	print("  -> reloaded from DB (using doc.name = %s):" % name)
	_show("DB", fresh)

	derived_if_vi = 400 * 5 / 1000.0 * 12          # 24.0 kWh
	print("\n  daily_kwh if P=V*I were derived from the new V/A: %s" % derived_if_vi)
	print("  actual daily_kwh                                     : %s"
		  % fresh.estimated_daily_consumption_kwh)
	print("  LINKAGE PRESENT: %s" % (
		abs(fresh.estimated_daily_consumption_kwh - derived_if_vi) < 1e-9))

	# Also prove the reverse: changing the RATING does move the estimates.
	fresh.power_rating_w = 400 * 5   # 2000 W
	fresh.save(ignore_permissions=True)
	print("\n  after setting rating=2000W (V/A untouched):")
	_show("RATING", fresh)
	print("  (rating -> estimate linkage IS present: %s)"
		  % (abs(fresh.estimated_daily_consumption_kwh - 24.0) < 1e-9))

	frappe.delete_doc("Device", name, force=1, ignore_permissions=True)
	print("\n(cleaned up)")

	left = frappe.get_all("Device", filters={"device_name": "Volt Test"}, pluck="name")
	print("stray 'Volt Test' rows remaining:", left)
	print("all devices now:", frappe.get_all("Device", pluck="name"))
PYEOF
bench --site "$SITE" execute robotics_lab._diag.volt_test2.run
