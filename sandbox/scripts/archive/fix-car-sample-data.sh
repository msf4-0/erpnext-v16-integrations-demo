#!/usr/bin/env bash
# Create SAMPLE DATA for the car_tracker app: 5 Car Workshops and 6 Cars with
# realistic Malaysian service histories (MYR costs).
#
# Deliberately designed so the derived fields demonstrate every case:
#   - service_status: OK / Due Soon / Overdue (by date) / Overdue (by mileage)
#     / No Service History
#   - workshops_used: 0, 1, 2 and 3
#   - last_workshop: newest row that has one (blank rows skipped)
#   - one historical row references an INACTIVE workshop (Old Town Motors),
#     which is realistic (a shop you used before it closed) and demonstrates
#     the inactive-workshop warning.
#
# Idempotent: deletes any existing sample records (matched by plate / workshop
# name) before re-creating them.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

APP_DIR=apps/car_tracker/car_tracker
mkdir -p "$APP_DIR/_sample"
cat > "$APP_DIR/_sample/__init__.py" <<'PYEOF'
PYEOF
cat > "$APP_DIR/_sample/run.py" <<'PYEOF'
import frappe
from frappe.utils import add_days, today

WORKSHOPS = [
	{
		"workshop_name": "Shah Alam Auto Care",
		"workshop_code": "SAAC",
		"status": "Active",
		"contact_person": "Ahmad Faizal",
		"phone": "+60355123456",
		"email_id": "service@shahalamautocare.example",
		"city": "Shah Alam",
		"address_line": "12 Jalan Perindustrian 3, Seksyen 15, 40200 Shah Alam, Selangor",
		"specialties": "Japanese & Korean makes; engine diagnostics; scheduled servicing",
		"hourly_rate": 120,
		"rating": "5",
		"notes": "Preferred workshop. Books out about a week ahead.",
	},
	{
		"workshop_name": "KL City Motor Works",
		"workshop_code": "KLCM",
		"status": "Active",
		"contact_person": "Lim Wei Sheng",
		"phone": "+60321112222",
		"email_id": "workshop@klcitymotor.example",
		"city": "Kuala Lumpur",
		"address_line": "88 Jalan Chan Sow Lin, 55200 Kuala Lumpur",
		"specialties": "Continental makes; air-conditioning; electrical fault finding",
		"hourly_rate": 95,
		"rating": "4",
	},
	{
		"workshop_name": "Precision Auto Garage",
		"workshop_code": "PRAG",
		"status": "Active",
		"contact_person": "Rajesh Kumar",
		"phone": "+60377889900",
		"email_id": "hello@precisionauto.example",
		"city": "Petaling Jaya",
		"address_line": "Lot 5, Jalan SS13/3, 47500 Subang Jaya, Selangor",
		"specialties": "Performance & suspension; 4x4 drivetrain; alignment",
		"hourly_rate": 150,
		"rating": "5",
	},
	{
		"workshop_name": "Budget Tyre & Service Centre",
		"workshop_code": "BTSC",
		"status": "Active",
		"contact_person": "Suresh a/l Maniam",
		"phone": "+60333445566",
		"email_id": "bookings@budgettyre.example",
		"city": "Klang",
		"address_line": "221 Jalan Kapar, 41400 Klang, Selangor",
		"specialties": "Tyres, balancing, batteries, fast oil changes",
		"hourly_rate": 70,
		"rating": "3",
		"notes": "Walk-in friendly; good for quick jobs.",
	},
	{
		"workshop_name": "Old Town Motors",
		"workshop_code": "OTKM",
		"status": "Inactive",
		"contact_person": "Tan Boon Hock",
		"phone": "+60387654321",
		"email_id": "enquiries@oldtownmotors.example",
		"city": "Kajang",
		"address_line": "9 Jalan Besar, 43000 Kajang, Selangor",
		"specialties": "General repairs (closed for renovation)",
		"hourly_rate": 80,
		"rating": "2",
		"notes": "Closed for renovation — retained for historical service records.",
	},
]

CARS = [
	{
		"license_plate": "WXY 1234",
		"make": "Toyota",
		"model": "Hilux 2.4G",
		"manufacture_year": 2020,
		"vin": "MR0HA8CD100123456",
		"body_type": "Pickup",
		"fuel_type": "Diesel",
		"colour": "Silver",
		"status": "Active",
		"registration_expiry": add_days(today(), 210),
		"last_recorded_mileage": 62000,
		"mileage_recorded_on": add_days(today(), -3),
		"oil_change_interval_months": 6,
		"oil_change_interval_km": 5000,
		"service_interval_months": 12,
		"service_interval_km": 10000,
		"notes": "Main work vehicle. Tows a trailer.",
		"service_records": [
			{"service_type": "Oil Change", "service_date": add_days(today(), -29), "odometer": 60000,
			 "workshop": "Shah Alam Auto Care", "cost": 185, "notes": "Also replaced air filter."},
			{"service_type": "Brake Service", "service_date": add_days(today(), -131), "odometer": 55000,
			 "workshop": "Shah Alam Auto Care", "cost": 420, "notes": "Front pads and discs."},
			{"service_type": "Oil Change", "service_date": add_days(today(), -215), "odometer": 52000,
			 "workshop": "Precision Auto Garage", "cost": 210},
			{"service_type": "General Maintenance", "service_date": add_days(today(), -389), "odometer": 45000,
			 "workshop": "Shah Alam Auto Care", "cost": 680, "notes": "Major service."},
		],
	},
	{
		"license_plate": "VAB 5678",
		"make": "Honda",
		"model": "Civic 1.8 S",
		"manufacture_year": 2019,
		"vin": "MRHFC1670KT654321",
		"body_type": "Sedan",
		"fuel_type": "Petrol",
		"colour": "White",
		"status": "Active",
		"registration_expiry": add_days(today(), 75),
		"last_recorded_mileage": 84000,
		"mileage_recorded_on": add_days(today(), -8),
		"oil_change_interval_months": 6,
		"oil_change_interval_km": 5000,
		"service_interval_months": 12,
		"service_interval_km": 10000,
		"service_records": [
			{"service_type": "General Maintenance", "service_date": add_days(today(), -352), "odometer": 78000,
			 "workshop": "KL City Motor Works", "cost": 950, "notes": "Air-con service included."},
			{"service_type": "Oil Change", "service_date": add_days(today(), -455), "odometer": 72000,
			 "workshop": "KL City Motor Works", "cost": 160},
			{"service_type": "Tyre Rotation", "service_date": add_days(today(), -552), "odometer": 68000,
			 "workshop": "Budget Tyre & Service Centre", "cost": 120},
		],
	},
	{
		"license_plate": "PQR 9012",
		"make": "Perodua",
		"model": "Myvi 1.5 AV",
		"manufacture_year": 2022,
		"vin": "PM2BA1H000789012",
		"body_type": "Hatchback",
		"fuel_type": "Petrol",
		"colour": "Blue",
		"status": "Active",
		"registration_expiry": add_days(today(), 320),
		"last_recorded_mileage": 34000,
		"mileage_recorded_on": add_days(today(), -17),
		"oil_change_interval_months": 6,
		"oil_change_interval_km": 5000,
		"service_interval_months": 12,
		"service_interval_km": 10000,
		"notes": "Overdue for its annual service — book in.",
		"service_records": [
			{"service_type": "General Maintenance", "service_date": add_days(today(), -460), "odometer": 30000,
			 "workshop": "Budget Tyre & Service Centre", "cost": 380},
			{"service_type": "Oil Change", "service_date": add_days(today(), -585), "odometer": 27000,
			 "workshop": "Budget Tyre & Service Centre", "cost": 130},
		],
	},
	{
		"license_plate": "JKL 3456",
		"make": "Nissan",
		"model": "Navara VL",
		"manufacture_year": 2018,
		"vin": "VSKCVND40U0123456",
		"body_type": "Pickup",
		"fuel_type": "Diesel",
		"colour": "Black",
		"status": "Active",
		"registration_expiry": add_days(today(), 140),
		"last_recorded_mileage": 145000,
		"mileage_recorded_on": add_days(today(), -2),
		"oil_change_interval_months": 6,
		"oil_change_interval_km": 5000,
		"service_interval_months": 12,
		"service_interval_km": 10000,
		"notes": "High mileage — overdue on the distance schedule.",
		"service_records": [
			{"service_type": "General Maintenance", "service_date": add_days(today(), -17), "odometer": 130000,
			 "workshop": "Precision Auto Garage", "cost": 1250, "notes": "Drivetrain inspection."},
			{"service_type": "Oil Change", "service_date": add_days(today(), -100), "odometer": 122000,
			 "workshop": "Precision Auto Garage", "cost": 220},
			{"service_type": "Brake Service", "service_date": add_days(today(), -241), "odometer": 112000,
			 "workshop": "Shah Alam Auto Care", "cost": 540},
		],
	},
	{
		"license_plate": "MNO 7890",
		"make": "BMW",
		"model": "320i Sport",
		"manufacture_year": 2021,
		"vin": "WBA5E5100MG987654",
		"body_type": "Sedan",
		"fuel_type": "Petrol",
		"colour": "Grey",
		"status": "Active",
		"registration_expiry": add_days(today(), 180),
		"last_recorded_mileage": 45000,
		"mileage_recorded_on": add_days(today(), -6),
		"oil_change_interval_months": 6,
		"oil_change_interval_km": 5000,
		"service_interval_months": 12,
		"service_interval_km": 10000,
		"notes": "One historical repair was done by Old Town Motors before it closed.",
		"service_records": [
			{"service_type": "Oil Change", "service_date": add_days(today(), -55), "odometer": 44000,
			 "workshop": "Precision Auto Garage", "cost": 320},
			{"service_type": "General Maintenance", "service_date": add_days(today(), -216), "odometer": 38000,
			 "workshop": "KL City Motor Works", "cost": 1180},
			{"service_type": "Repair", "service_date": add_days(today(), -317), "odometer": 33000,
			 "workshop": "Old Town Motors", "cost": 760, "notes": "Coolant leak repair (now closed)."},
		],
	},
	{
		"license_plate": "STU 2468",
		"make": "Tesla",
		"model": "Model 3 Long Range",
		"manufacture_year": 2023,
		"vin": "5YJ3E1EA000246810",
		"body_type": "Sedan",
		"fuel_type": "Electric",
		"colour": "Red",
		"status": "Active",
		"registration_expiry": add_days(today(), 400),
		"last_recorded_mileage": 18000,
		"mileage_recorded_on": add_days(today(), -4),
		"oil_change_interval_months": 6,
		"oil_change_interval_km": 5000,
		"service_interval_months": 12,
		"service_interval_km": 10000,
		"notes": "EV — no oil changes. No service history recorded yet.",
		"service_records": [],
	},
]


def _reset_workshop(name):
	if frappe.db.exists("Car Workshop", {"workshop_name": name}):
		frappe.delete_doc("Car Workshop", frappe.db.get_value("Car Workshop", {"workshop_name": name}, "name"), force=1, ignore_permissions=True)


def _reset_car(plate):
	if frappe.db.exists("Car", {"license_plate": plate}):
		frappe.delete_doc("Car", frappe.db.get_value("Car", {"license_plate": plate}, "name"), force=1, ignore_permissions=True)


def create():
	frappe.set_user("Administrator")

	# Remove any previous run's sample records (idempotent re-run).
	for c in CARS:
		_reset_car(c["license_plate"])
	for w in WORKSHOPS:
		_reset_workshop(w["workshop_name"])
	frappe.db.commit()

	# If the tables are now EMPTY, restart the naming series at 1 so the sample
	# data reads CAR-0001.. / WS-0001.. rather than continuing from earlier test
	# runs. Guarded: if any records remain (i.e. real data exists), leave the
	# counters alone.
	if not frappe.db.count("Car") and not frappe.db.count("Car Workshop"):
		frappe.db.sql("update `tabSeries` set `current`=0 where name in ('CAR-', 'WS-')")
		frappe.db.commit()
		print("series counters reset: CAR- and WS- start at 1")
	else:
		print("WARNING: tables not empty after cleanup — leaving series counters untouched")

	print("== creating workshops ==")
	# The Link field stores the DOCUMENT NAME (series WS-.####), not the
	# workshop_name — so map name -> doc name for the service rows below.
	ws_map = {}
	for w in WORKSHOPS:
		doc = frappe.get_doc({"doctype": "Car Workshop", **w}).insert(ignore_permissions=True)
		ws_map[doc.workshop_name] = doc.name
		print(f"  {doc.name}  {doc.workshop_name}  [{doc.status}]")

	print("== creating cars ==")
	for c in CARS:
		data = {k: v for k, v in c.items() if k != "service_records"}
		rows = c.get("service_records") or []
		doc = frappe.get_doc({
			"doctype": "Car",
			"naming_series": "CAR-.####",
			**data,
		})
		for r in rows:
			r = dict(r)
			r["workshop"] = ws_map[r["workshop"]]  # resolve to the Link value
			doc.append("service_records", r)
		doc.insert(ignore_permissions=True)
		print(
			f"  {doc.name}  {doc.license_plate:9} {doc.make} {doc.model:20} "
			f"status={doc.service_status:18} last_ws={doc.last_workshop or '-':8} "
			f"used={doc.workshops_used} cost={doc.total_maintenance_cost}"
		)

	frappe.db.commit()
	print("\nDONE: workshops =", frappe.db.count("Car Workshop"), " cars =", frappe.db.count("Car"),
		  " service rows =", frappe.db.count("Car Service Record"))
PYEOF

bench --site "$SITE" execute car_tracker._sample.run.create
rm -rf "$APP_DIR/_sample"
