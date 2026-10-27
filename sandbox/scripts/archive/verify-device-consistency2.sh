#!/usr/bin/env bash
# Verify the V x I vs Power Rating consistency warning WORKS, and that it does
# NOT fire where it would be noise (missing / zero fields).
#
# HARNESS FIX (first attempt was wrong): frappe.msgprint records into
# frappe.local.message_log, NOT doc._messages. Capturing the wrong attribute is
# why every case looked "silent". Assert on frappe.local.message_log instead.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

mkdir -p apps/robotics_lab/robotics_lab/_diag
touch apps/robotics_lab/robotics_lab/_diag/__init__.py
cat > apps/robotics_lab/robotics_lab/_diag/consistency.py <<'PYEOF'
import frappe


def _msgs(**kw):
	base = {"doctype": "Device", "device_name": "Consistency Test",
			"device_type": "Light", "status": "Idle"}
	base.update(kw)
	doc = frappe.get_doc(base)
	frappe.local.message_log = []
	doc.run_method("validate")
	log = frappe.local.message_log or []
	frappe.local.message_log = []
	return [m.get("message", "") for m in log]


def run():
	frappe.set_user("Administrator")
	results = []

	def case(label, expect_warn, **kw):
		msgs = _msgs(**kw)
		va = [m for m in msgs if "Voltage x Current" in m]
		got = bool(va)
		ok = got == expect_warn
		results.append((label, "warn" if got else "silent",
						"OK" if ok else "*** WRONG ***",
						(va[0][:64] if va else "")))

	case("mismatch 500W vs 2000VA", True,
		 power_rating_w=500, voltage_v=400, current_a=5)
	case("consistent 460W vs 460VA", False,
		 power_rating_w=460, voltage_v=230, current_a=2)
	case("within 5% tol (494.5VA)", False,
		 power_rating_w=500, voltage_v=230, current_a=2.15)
	case("inductive 500W vs 690VA", True,
		 power_rating_w=500, voltage_v=230, current_a=3)
	case("voltage missing", False, power_rating_w=500, current_a=5)
	case("current missing", False, power_rating_w=500, voltage_v=230)
	case("rating missing", False, voltage_v=230, current_a=5)
	case("all zero", False, power_rating_w=0, voltage_v=0, current_a=0)
	case("rating only", False, power_rating_w=500)
	case("blank strings", False, power_rating_w=500, voltage_v="", current_a="")

	print("=== POWER CONSISTENCY CHECK ===")
	print(f"{'case':30} | {'result':7} | {'verdict':12} | message")
	for c in results:
		print(f"{c[0]:30} | {c[1]:7} | {c[2]:12} | {c[3]}")
	bad = [c for c in results if "WRONG" in c[2]]
	print("\nFAILURES:", len(bad))
	for b in bad:
		print("  ", b)

	# Prove it never overwrites the rating.
	frappe.local.message_log = []
	d = frappe.get_doc({
		"doctype": "Device", "device_name": "NeverOverwrite",
		"device_type": "Light", "status": "Idle",
		"power_rating_w": 500, "voltage_v": 400, "current_a": 5,
		"daily_operating_hours": 10,
	}).insert(ignore_permissions=True)
	print("\nnever-overwrite: rating=%s (input 500), daily_kwh=%s (expect 5.0)"
		  % (d.power_rating_w, d.estimated_daily_consumption_kwh))
	warned = any("Voltage x Current" in m.get("message", "")
				 for m in (frappe.local.message_log or []))
	print("warned on insert (real save path):", warned)
	frappe.delete_doc("Device", d.name, force=1, ignore_permissions=True)

	# Regression: the earlier consumption rules still hold.
	frappe.local.message_log = []
	e = frappe.get_doc({
		"doctype": "Device", "device_name": "Regress", "device_type": "Robot",
		"status": "Active", "power_rating_w": 500, "daily_operating_hours": 12,
	}).insert(ignore_permissions=True)
	print("regression 500W x 12h -> daily=%s annual=%s (expect 6.0 / 2190.0)"
		  % (e.estimated_daily_consumption_kwh, e.estimated_annual_consumption_kwh))
	frappe.delete_doc("Device", e.name, force=1, ignore_permissions=True)

	# Regression: >24h still rejected.
	try:
		frappe.get_doc({
			"doctype": "Device", "device_name": "Regress2",
			"device_type": "Robot", "status": "Active",
			"power_rating_w": 100, "daily_operating_hours": 25,
		}).insert(ignore_permissions=True)
		print("regression >24h: NO ERROR - BUG")
	except frappe.ValidationError:
		print("regression >24h: rejected OK")
PYEOF
bench --site "$SITE" execute robotics_lab._diag.consistency.run
