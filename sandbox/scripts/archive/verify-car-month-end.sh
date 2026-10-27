#!/usr/bin/env bash
# Confirm add_months month-end clamping behaves sanely for the Car next-due
# derivation (a Jan-31 service on a 1-month schedule must not produce an
# invalid date or crash), and that the controller stores it.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

APP_DIR=apps/car_tracker/car_tracker
mkdir -p "$APP_DIR/_diag"
cat > "$APP_DIR/_diag/__init__.py" <<'PYEOF'
PYEOF
cat > "$APP_DIR/_diag/run.py" <<'PYEOF'
import frappe
from frappe.utils import add_months, getdate


def month_edges():
	frappe.set_user("Administrator")
	results = []

	# raw add_months clamping
	for start, months in (("2026-01-31", 1), ("2026-08-31", 6), ("2026-03-31", 1), ("2026-02-28", 12)):
		results.append((f"add_months({start},{months})", str(add_months(start, months))))

	# a Car whose oil service is on a month-end, 1-month interval
	if frappe.db.exists("Car", {"license_plate": "DIAG-MONTHEND"}):
		frappe.delete_doc("Car", frappe.db.get_value("Car", {"license_plate": "DIAG-MONTHEND"}, "name"), force=1)
	doc = frappe.get_doc({
		"doctype": "Car",
		"license_plate": "DIAG-MONTHEND",
		"make": "Test",
		"model": "Edge",
		"status": "Active",
		"last_recorded_mileage": 1000,
		"oil_change_interval_months": 1,
		"oil_change_interval_km": 1000,
	})
	doc.append("service_records", {
		"service_type": "Oil Change",
		"service_date": "2026-01-31",
		"odometer": 1000,
	})
	doc.insert(ignore_permissions=True)
	results.append(("car next_oil_due", str(doc.next_oil_change_due_date)))
	results.append(("car next_oil_km", str(doc.next_oil_change_due_mileage)))
	doc.delete()

	print("=== MONTH-END RESULTS ===")
	for label, value in results:
		print(f"{label:34} | {value}")
PYEOF

bench --site "$SITE" execute car_tracker._diag.run.month_edges
rm -rf "$APP_DIR/_diag"
