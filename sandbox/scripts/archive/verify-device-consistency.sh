#!/usr/bin/env bash
# Verify the V x I vs Power Rating consistency warning WORKS, and that it does
# NOT fire in the cases where it would be noise (missing / zero fields).
#
# The warning is raised via frappe.msgprint, which in a script context does NOT
# raise — so assert on the captured messages rather than on "no exception".
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

mkdir -p apps/robotics_lab/robotics_lab/_diag
touch apps/robotics_lab/robotics_lab/_diag/__init__.py
cat > apps/robotics_lab/robotics_lab/_diag/consistency.py <<'PYEOF'
import frappe


def _msgs(doc):
	"""Run validation and return the messages it produced.

	frappe.msgprint queues messages on the doc; _validate() is what
	Document.insert() calls, so this exercises the real path.
	"""
	doc._messages = []
	doc.run_method("validate")
	return [m.message for m in doc._messages]


def _mk(**kw):
	base = {"doctype": "Device", "device_name": "Consistency Test",
			"device_type": "Light", "status": "Idle"}
	base.update(kw)
	return frappe.get_doc(base)


def run():
	frappe.set_user("Administrator")
	results = []

	def case(label, expect_warn, **kw):
		msgs = _msgs(_mk(**kw))
		va = [m for m in msgs if "Voltage x Current" in m]
		got = bool(va)
		ok = got == expect_warn
		results.append((label, "warn" if got else "silent",
						"OK" if ok else "*** WRONG ***",
						(va[0][:70] if va else "")))

	# 1. clear mismatch: 500W rating vs 400*5=2000VA  -> WARN
	case("mismatch 500W vs 2000VA", True,
		 power_rating_w=500, voltage_v=400, current_a=5)

	# 2. consistent: 460W rating vs 230*2 = 460VA -> SILENT (exact)
	case("consistent 460W vs 460VA", False,
		 power_rating_w=460, voltage_v=230, current_a=2)

	# 3. within tolerance: 500W vs 230*2.15=494.5VA (1.1% off) -> SILENT
	case("within 5% tol", False,
		 power_rating_w=500, voltage_v=230, current_a=2.15)

	# 4. real-world inductive: 500W real vs 230*3=690VA (38% apparent) -> WARN
	#    (correct behaviour: it flags for review, user decides)
	case("inductive 500W vs 690VA", True,
		 power_rating_w=500, voltage_v=230, current_a=3)

	# 5. no voltage -> SILENT (must not nag)
	case("voltage missing", False, power_rating_w=500, current_a=5)

	# 6. no current -> SILENT
	case("current missing", False, power_rating_w=500, voltage_v=230)

	# 7. no rating -> SILENT
	case("rating missing", False, voltage_v=230, current_a=5)

	# 8. all zero -> SILENT
	case("all zero", False, power_rating_w=0, voltage_v=0, current_a=0)

	# 9. rating only -> SILENT
	case("rating only", False, power_rating_w=500)

	print("=== POWER CONSISTENCY CHECK ===")
	print(f"{'case':30} | {'result':7} | {'verdict':12} | message")
	for c in results:
		print(f"{c[0]:30} | {c[1]:7} | {c[2]:12} | {c[3]}")
	bad = [c for c in results if "WRONG" in c[2]]
	print("\nFAILURES:", len(bad))
	for b in bad:
		print("  ", b)

	# 10. prove it never OVERWRITES the rating
	d = _mk(power_rating_w=500, voltage_v=400, current_a=5, daily_operating_hours=10)
	d.insert(ignore_permissions=True)
	print("\nnever-overwrite check: rating=%s (input 500) daily_kwh=%s (500*10/1000=5.0)"
		  % (d.power_rating_w, d.estimated_daily_consumption_kwh))
	frappe.delete_doc("Device", d.name, force=1, ignore_permissions=True)
PYEOF
bench --site "$SITE" execute robotics_lab._diag.consistency.run
