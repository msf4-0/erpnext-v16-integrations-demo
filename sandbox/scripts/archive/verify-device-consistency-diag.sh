#!/usr/bin/env bash
# Diagnose why the consistency msgprint didn't appear: is it my TEST HARNESS
# (msgprint capture) or the actual code? Check both directly.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

echo "== 1. is the new validate_power_consistency method present in the running app? =="
grep -n "def validate_power_consistency\|def validate\b" \
  apps/robotics_lab/robotics_lab/robotics_lab/doctype/device/device.py

echo
echo "== 2. does the module import and expose the method? =="
mkdir -p apps/robotics_lab/robotics_lab/_diag
touch apps/robotics_lab/robotics_lab/_diag/__init__.py
cat > apps/robotics_lab/robotics_lab/_diag/diag.py <<'PYEOF'
import frappe


def run():
	frappe.set_user("Administrator")

	from robotics_lab.robotics_lab.doctype.device.device import Device, VA_WARN_TOLERANCE
	print("  class:", Device.__name__)
	print("  has validate_power_consistency:", hasattr(Device, "validate_power_consistency"))
	print("  tolerance:", VA_WARN_TOLERANCE)

	# Build the doc WITHOUT running validate at construction.
	d = frappe.get_doc({
		"doctype": "Device", "device_name": "Diag", "device_type": "Light",
		"status": "Idle", "power_rating_w": 500, "voltage_v": 400, "current_a": 5,
	})
	print("\n  inputs: rating=%s V=%s A=%s -> expected VA=%s"
		  % (d.power_rating_w, d.voltage_v, d.current_a, 400 * 5))

	# 2a. call the method directly, inspect frappe's message log
	frappe.flags.mute_messages = False
	d.validate_power_consistency()
	print("  direct call: doc._messages =", len(getattr(d, "_messages", [])))
	print("  frappe.message_log:", [m.get("message", "")[:60] for m in (frappe.local.message_log or [])])
	# 2b. via run_method (what the test harness used)
	frappe.local.message_log = []
	d.run_method("validate_power_consistency")
	print("  run_method: frappe.message_log:",
		  [m.get("message", "")[:60] for m in (frappe.local.message_log or [])])

	# 2c. full validate()
	frappe.local.message_log = []
	d.run_method("validate")
	log = frappe.local.message_log or []
	print("  full validate(): %d message(s)" % len(log))
	for m in log:
		print("    -", m.get("message", "")[:90])
PYEOF
bench --site "$SITE" execute robotics_lab._diag.diag.run
