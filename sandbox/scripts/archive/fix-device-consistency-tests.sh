#!/usr/bin/env bash
# Add real unit tests for the power-consistency check to the app's test
# module, so the behaviour is covered by `run-tests --app robotics_lab`
# (not just by ad-hoc scripts).
set -uo pipefail
APP=robotics_lab
DT="/home/frappe/frappe-bench/apps/$APP/$APP/$APP/doctype/device"
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

cat > "$DT/test_device.py" <<'TESTEOF'
# -*- coding: utf-8 -*-
"""Tests for the Device doctype: power-consumption estimates and the
Voltage x Current vs Power Rating consistency check."""

import frappe
from frappe.tests.utils import FrappeTestCase


class TestDevice(FrappeTestCase):
	def make_device(self, **kwargs):
		return frappe.get_doc(
			{
				"doctype": "Device",
				"device_name": "Test Device",
				"device_type": "Robot",
				"status": "Active",
				**kwargs,
			}
		)

	def captured_messages(self, doc):
		"""Run validate() and return the queued messages.

		frappe.msgprint writes to frappe.local.message_log (NOT doc._messages).
		"""
		frappe.local.message_log = []
		doc.run_method("validate")
		log = frappe.local.message_log or []
		frappe.local.message_log = []
		return [m.get("message", "") for m in log]

	# --- consumption estimates -------------------------------------------

	def test_consumption_computed_on_save(self):
		doc = self.make_device(power_rating_w=500, daily_operating_hours=12)
		doc.insert()
		self.assertEqual(doc.estimated_daily_consumption_kwh, 6.0)
		self.assertEqual(doc.estimated_annual_consumption_kwh, 2190.0)
		doc.delete()

	def test_zero_rating_yields_zero_consumption(self):
		doc = self.make_device(power_rating_w=0, daily_operating_hours=10)
		doc.insert()
		self.assertEqual(doc.estimated_daily_consumption_kwh, 0.0)
		self.assertEqual(doc.estimated_annual_consumption_kwh, 0.0)
		doc.delete()

	def test_missing_power_fields_do_not_raise(self):
		doc = self.make_device()
		doc.insert()
		self.assertEqual(doc.estimated_daily_consumption_kwh, 0.0)
		doc.delete()

	def test_operating_hours_over_24_rejected(self):
		doc = self.make_device(power_rating_w=100, daily_operating_hours=25)
		self.assertRaises(frappe.ValidationError, doc.insert)

	def test_full_day_operating_hours_allowed(self):
		doc = self.make_device(power_rating_w=100, daily_operating_hours=24)
		doc.insert()
		self.assertEqual(doc.estimated_daily_consumption_kwh, 2.4)
		doc.delete()

	def test_negative_operating_hours_rejected(self):
		doc = self.make_device(power_rating_w=100, daily_operating_hours=-1)
		self.assertRaises(frappe.ValidationError, doc.insert)

	def test_estimated_fields_recomputed_on_update(self):
		doc = self.make_device(power_rating_w=500, daily_operating_hours=12)
		doc.insert()
		doc.daily_operating_hours = 6
		doc.save()
		self.assertEqual(doc.estimated_daily_consumption_kwh, 3.0)
		doc.delete()

	# --- voltage/current vs rating consistency ----------------------------

	def test_mismatch_rating_vs_va_warns(self):
		doc = self.make_device(power_rating_w=500, voltage_v=400, current_a=5)
		msgs = self.captured_messages(doc)
		self.assertTrue(any("Voltage x Current" in m for m in msgs))

	def test_consistent_rating_and_va_is_silent(self):
		doc = self.make_device(power_rating_w=460, voltage_v=230, current_a=2)
		msgs = self.captured_messages(doc)
		self.assertFalse(any("Voltage x Current" in m for m in msgs))

	def test_small_difference_within_tolerance_is_silent(self):
		# 230 * 2.15 = 494.5 VA vs 500 W => ~1.1% off, inside the 5% tolerance.
		doc = self.make_device(power_rating_w=500, voltage_v=230, current_a=2.15)
		msgs = self.captured_messages(doc)
		self.assertFalse(any("Voltage x Current" in m for m in msgs))

	def test_incomplete_electrical_data_does_not_warn(self):
		for kwargs in (
			{"power_rating_w": 500, "current_a": 5},
			{"power_rating_w": 500, "voltage_v": 230},
			{"voltage_v": 230, "current_a": 5},
			{"power_rating_w": 0, "voltage_v": 0, "current_a": 0},
		):
			with self.subTest(kwargs=kwargs):
				doc = self.make_device(**kwargs)
				msgs = self.captured_messages(doc)
				self.assertFalse(any("Voltage x Current" in m for m in msgs))

	def test_consistency_check_never_overwrites_rating(self):
		doc = self.make_device(
			power_rating_w=500, voltage_v=400, current_a=5, daily_operating_hours=10
		)
		doc.insert()
		self.assertEqual(doc.power_rating_w, 500)
		self.assertEqual(doc.estimated_daily_consumption_kwh, 5.0)
		doc.delete()
TESTEOF

echo "== test file written ($(grep -c 'def test_' "$DT/test_device.py") tests) =="
grep -n "def test_" "$DT/test_device.py"

echo
echo "== run the suite =="
bench --site "$SITE" run-tests --app "$APP" 2>&1 | tail -30

echo
echo "== stage updated source for the host copy =="
rm -rf /tmp/devfix2 && mkdir -p /tmp/devfix2
cp "$DT/device.py" "$DT/device.js" "$DT/test_device.py" /tmp/devfix2/
ls -la /tmp/devfix2/
