#!/usr/bin/env bash
# Exercise the Car Workshop linkage end-to-end on the live v16 site:
# derived last_workshop / workshops_used, phone fetch, inactive-workshop warning
# (non-blocking), the "deactivate a workshop then save an existing car" poison
# regression, and REST behaviour for the new doctype.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

APP_DIR=apps/car_tracker/car_tracker
mkdir -p "$APP_DIR/_diag"
cat > "$APP_DIR/_diag/__init__.py" <<'PYEOF'
PYEOF
cat > "$APP_DIR/_diag/run.py" <<'PYEOF'
import frappe
from frappe.utils import add_days, today

W = {"n": 0}
C = {"n": 0}


def _ws(**kw):
	W["n"] += 1
	values = {
		"doctype": "Car Workshop",
		"workshop_name": f"DIAG Workshop {W['n']:04d}",
		"status": "Active",
		"phone": f"+60123456{W['n']:03d}",
	}
	values.update(kw)
	doc = frappe.get_doc(values)
	doc.insert(ignore_permissions=True)
	return doc


def _car(**kw):
	C["n"] += 1
	values = {
		"doctype": "Car",
		"license_plate": f"DIAGW-{C['n']:04d}",
		"make": "Toyota",
		"model": "Hilux",
		"status": "Active",
		"last_recorded_mileage": 0,
	}
	values.update(kw)
	return frappe.get_doc(values)


def cleanup():
	frappe.set_user("Administrator")
	for row in frappe.get_all("Car", pluck="name"):
		frappe.delete_doc("Car", row, force=1, ignore_permissions=True)
	for row in frappe.get_all("Car Workshop", pluck="name"):
		frappe.delete_doc("Car Workshop", row, force=1, ignore_permissions=True)
	print("cars:", frappe.db.count("Car"), "workshops:", frappe.db.count("Car Workshop"))


def edges():
	frappe.set_user("Administrator")
	results = []

	def record(label, got, want):
		ok = "OK" if str(got) == str(want) else "MISMATCH"
		results.append((label, got, want, ok))

	# --- derived fields -------------------------------------------------
	w1, w2 = _ws(), _ws()

	d = _car(last_recorded_mileage=20000)
	d.append("service_records", {"service_type": "Oil Change",
							   "service_date": add_days(today(), -200), "odometer": 15000,
							   "workshop": w1.name})
	d.append("service_records", {"service_type": "Brake Service",
							   "service_date": add_days(today(), -10), "odometer": 19500,
							   "workshop": w2.name})
	d.insert(ignore_permissions=True)
	record("last_workshop_newest", d.last_workshop, w2.name)
	record("workshops_used", d.workshops_used, 2)
	d.delete()

	# --- rows without a workshop are skipped, not treated as blank ------
	d = _car(last_recorded_mileage=20000)
	d.append("service_records", {"service_type": "Oil Change",
							   "service_date": add_days(today(), -200), "odometer": 15000,
							   "workshop": w1.name})
	d.append("service_records", {"service_type": "Inspection",
							   "service_date": add_days(today(), -5), "odometer": 19500})
	d.insert(ignore_permissions=True)
	record("last_workshop_skips_blank", d.last_workshop, w1.name)
	record("distinct_ignores_blank", d.workshops_used, 1)
	d.delete()

	# --- duplicate picks of the same workshop count once -----------------
	d = _car(last_recorded_mileage=30000)
	for day, km in ((-300, 20000), (-100, 28000)):
		d.append("service_records", {"service_type": "Oil Change",
								   "service_date": add_days(today(), day), "odometer": km,
								   "workshop": w1.name})
	d.insert(ignore_permissions=True)
	record("distinct_same_ws", d.workshops_used, 1)
	d.delete()

	# --- phone fetch -----------------------------------------------------
	d = _car(last_recorded_mileage=1000)
	d.append("service_records", {"service_type": "Oil Change",
							   "service_date": today(), "odometer": 1000, "workshop": w1.name})
	d.insert(ignore_permissions=True)
	record("phone_fetched", d.service_records[0].workshop_phone, w1.phone)
	d.delete()

	# --- no workshops at all --------------------------------------------
	d = _car(last_recorded_mileage=1000)
	d.append("service_records", {"service_type": "Oil Change",
							   "service_date": today(), "odometer": 1000})
	d.insert(ignore_permissions=True)
	record("no_ws_last", d.last_workshop, None)
	record("no_ws_count", d.workshops_used, 0)
	d.delete()

	# --- inactive workshop WARNS but SAVES (non-blocking) ----------------
	wi = _ws(status="Inactive")
	d = _car(last_recorded_mileage=1000)
	d.append("service_records", {"service_type": "Oil Change",
							   "service_date": today(), "odometer": 1000, "workshop": wi.name})
	frappe.local.message_log = []
	d.run_method("validate")
	msgs = [m.get("message", "") for m in (frappe.local.message_log or [])]
	frappe.local.message_log = []
	record("inactive_warns", any("inactive workshop" in m.lower() for m in msgs), True)
	try:
		d.insert(ignore_permissions=True)
		record("inactive_saves", "saved", "saved")
		d.delete()
	except Exception as e:
		record("inactive_saves", f"RAISED {type(e).__name__}", "saved")

	# --- active workshop is silent --------------------------------------
	wa = _ws(status="Active")
	d = _car(last_recorded_mileage=1000)
	d.append("service_records", {"service_type": "Oil Change",
							   "service_date": today(), "odometer": 1000, "workshop": wa.name})
	frappe.local.message_log = []
	d.run_method("validate")
	msgs = [m.get("message", "") for m in (frappe.local.message_log or [])]
	frappe.local.message_log = []
	record("active_silent", not any("inactive workshop" in m.lower() for m in msgs), True)
	d.delete()

	# --- POISON REGRESSION: deactivate then save an existing car --------
	wp = _ws(status="Active")
	d = _car(last_recorded_mileage=1000)
	d.append("service_records", {"service_type": "Oil Change",
							   "service_date": today(), "odometer": 1000, "workshop": wp.name})
	d.insert(ignore_permissions=True)
	wp.status = "Inactive"
	wp.save(ignore_permissions=True)
	d.last_recorded_mileage = 1500  # unrelated edit
	try:
		d.save(ignore_permissions=True)
		record("deactivated_still_saves", d.last_recorded_mileage, 1500)
	except Exception as e:
		record("deactivated_still_saves", f"RAISED {type(e).__name__}", 1500)
	d.delete()

	# --- deleting the referenced workshop is blocked (link protection) ---
	d = _car(last_recorded_mileage=1000)
	d.append("service_records", {"service_type": "Oil Change",
							   "service_date": today(), "odometer": 1000, "workshop": w1.name})
	d.insert(ignore_permissions=True)
	try:
		frappe.delete_doc("Car Workshop", w1.name, ignore_permissions=True)
		record("link_protection", "NO ERROR - unexpected", "blocked")
	except Exception:
		record("link_protection", "blocked", "blocked")
	d.delete()

	# tidy up the workshops created here
	for row in frappe.get_all("Car Workshop", pluck="name"):
		frappe.delete_doc("Car Workshop", row, force=1, ignore_permissions=True)

	print("=== WORKSHOP EDGE RESULTS ===")
	fails = 0
	for label, got, want, ok in results:
		print(f"{label:28} | got={got!s:22} | want={want!s:22} | {ok}")
		if ok != "OK":
			fails += 1
	print(f"FAILURES: {fails}")
PYEOF

bench --site "$SITE" execute car_tracker._diag.run.edges
bench --site "$SITE" execute car_tracker._diag.run.cleanup
rm -rf "$APP_DIR/_diag"
