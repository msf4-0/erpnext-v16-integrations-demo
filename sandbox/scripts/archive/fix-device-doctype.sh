#!/usr/bin/env bash
# Author the Device doctype (robotics lab devices + power metrics) into the
# installed robotics_lab app, then copy it back to the host source of truth.
#
# Why a script: host-side PowerShell is currently denied for this agent, and
# multi-line JSON/quote-heavy inline bash is the documented Windows quoting
# trap (see ./docs/WINDOWS-QUOTING.md). The sanctioned pattern is
# a script file copied in with `docker compose cp` and run inside the
# container.
#
# Usage: fix-device-doctype.sh <version>
set -uo pipefail

VERSION="${1:-16}"
APP=robotics_lab
APP_DIR="/home/frappe/frappe-bench/apps/$APP"
DT_DIR="$APP_DIR/$APP/$APP/doctype/device"
SITE="${SITE_NAME:-frontend}"

cd /home/frappe/frappe-bench || exit 1

if [ ! -d "$APP_DIR" ]; then
  echo "ERROR: $APP_DIR not found — is robotics_lab installed?"
  exit 1
fi

mkdir -p "$DT_DIR"

echo "== writing device.json =="
cat > "$DT_DIR/device.json" <<'JSONEOF'
{
 "actions": [],
 "allow_import": 1,
 "allow_rename": 1,
 "autoname": "naming_series:",
 "creation": "2026-09-17 00:00:00.000000",
 "doctype": "DocType",
 "document_type": "Document",
 "editable_grid": 1,
 "engine": "InnoDB",
 "field_order": [
  "naming_series",
  "device_name",
  "device_type",
  "status",
  "column_break_identity",
  "manufacturer",
  "model_number",
  "serial_number",
  "location",
  "commissioned_on",
  "power_section",
  "power_rating_w",
  "standby_power_w",
  "column_break_power",
  "voltage_v",
  "current_a",
  "power_source",
  "daily_operating_hours",
  "consumption_section",
  "estimated_daily_consumption_kwh",
  "column_break_consumption",
  "estimated_annual_consumption_kwh",
  "notes_section",
  "notes"
 ],
 "fields": [
  {
   "fieldname": "naming_series",
   "fieldtype": "Select",
   "label": "Series",
   "options": "DEV-.####",
   "reqd": 1
  },
  {
   "bold": 1,
   "fieldname": "device_name",
   "fieldtype": "Data",
   "in_global_search": 1,
   "in_list_view": 1,
   "label": "Device Name",
   "reqd": 1
  },
  {
   "fieldname": "device_type",
   "fieldtype": "Select",
   "in_list_view": 1,
   "in_standard_filter": 1,
   "label": "Device Type",
   "options": "Robot\nLight\nSensor\nActuator\nController\nOther",
   "reqd": 1
  },
  {
   "default": "Active",
   "fieldname": "status",
   "fieldtype": "Select",
   "in_list_view": 1,
   "in_standard_filter": 1,
   "label": "Status",
   "options": "Active\nIdle\nMaintenance\nOffline\nRetired",
   "reqd": 1
  },
  {
   "fieldname": "column_break_identity",
   "fieldtype": "Column Break"
  },
  {
   "fieldname": "manufacturer",
   "fieldtype": "Data",
   "label": "Manufacturer"
  },
  {
   "fieldname": "model_number",
   "fieldtype": "Data",
   "label": "Model Number"
  },
  {
   "fieldname": "serial_number",
   "fieldtype": "Data",
   "label": "Serial Number",
   "unique": 1
  },
  {
   "fieldname": "location",
   "fieldtype": "Data",
   "in_standard_filter": 1,
   "label": "Location"
  },
  {
   "fieldname": "commissioned_on",
   "fieldtype": "Date",
   "label": "Commissioned On"
  },
  {
   "fieldname": "power_section",
   "fieldtype": "Section Break",
   "label": "Power"
  },
  {
   "default": "0",
   "description": "Active power draw while operating, in watts.",
   "fieldname": "power_rating_w",
   "fieldtype": "Float",
   "in_list_view": 1,
   "label": "Power Rating (W)",
   "non_negative": 1
  },
  {
   "default": "0",
   "description": "Power draw while idle/standby, in watts.",
   "fieldname": "standby_power_w",
   "fieldtype": "Float",
   "label": "Standby Power (W)",
   "non_negative": 1
  },
  {
   "fieldname": "column_break_power",
   "fieldtype": "Column Break"
  },
  {
   "default": "0",
   "fieldname": "voltage_v",
   "fieldtype": "Float",
   "label": "Voltage (V)",
   "non_negative": 1
  },
  {
   "default": "0",
   "fieldname": "current_a",
   "fieldtype": "Float",
   "label": "Current (A)",
   "non_negative": 1
  },
  {
   "fieldname": "power_source",
   "fieldtype": "Select",
   "in_standard_filter": 1,
   "label": "Power Source",
   "options": "\nMains\nBattery\nPoE\nSolar\nOther"
  },
  {
   "default": "0",
   "description": "Average hours per day the device is powered on and operating (0-24). Used to estimate consumption.",
   "fieldname": "daily_operating_hours",
   "fieldtype": "Float",
   "label": "Daily Operating Hours",
   "non_negative": 1
  },
  {
   "collapsible": 1,
   "fieldname": "consumption_section",
   "fieldtype": "Section Break",
   "label": "Consumption Estimate"
  },
  {
   "description": "Computed server-side as Power Rating (W) x Daily Operating Hours / 1000.",
   "fieldname": "estimated_daily_consumption_kwh",
   "fieldtype": "Float",
   "in_list_view": 1,
   "label": "Estimated Daily Consumption (kWh)",
   "no_copy": 1,
   "precision": "4",
   "read_only": 1
  },
  {
   "fieldname": "column_break_consumption",
   "fieldtype": "Column Break"
  },
  {
   "description": "Computed server-side as Estimated Daily Consumption x 365.",
   "fieldname": "estimated_annual_consumption_kwh",
   "fieldtype": "Float",
   "label": "Estimated Annual Consumption (kWh)",
   "no_copy": 1,
   "precision": "4",
   "read_only": 1
  },
  {
   "fieldname": "notes_section",
   "fieldtype": "Section Break",
   "label": "Notes"
  },
  {
   "fieldname": "notes",
   "fieldtype": "Text Editor",
   "label": "Notes"
  }
 ],
 "icon": "fa fa-microchip",
 "index_web_pages_for_search": 1,
 "links": [],
 "modified": "2026-09-17 00:00:00.000000",
 "modified_by": "Administrator",
 "module": "Robotics Lab",
 "name": "Device",
 "naming_rule": "By \"Naming Series\" field",
 "owner": "Administrator",
 "permissions": [
  {
   "create": 1,
   "delete": 1,
   "email": 1,
   "export": 1,
   "print": 1,
   "read": 1,
   "report": 1,
   "role": "System Manager",
   "share": 1,
   "write": 1
  },
  {
   "create": 1,
   "delete": 0,
   "email": 1,
   "export": 1,
   "print": 1,
   "read": 1,
   "report": 1,
   "role": "All",
   "share": 1,
   "write": 1
  }
 ],
 "sort_field": "creation",
 "sort_order": "DESC",
 "states": [],
 "track_changes": 1
}
JSONEOF

echo "== writing device.py =="
cat > "$DT_DIR/device.py" <<'PYEOF'
# -*- coding: utf-8 -*-
"""Device — a robotics lab device (robot, light, sensor, ...) plus its power
consumption metrics.

Consumption is modelled as a steady-state estimate derived from the device's
rated power and its average daily operating hours:

    estimated_daily_consumption_kwh  = power_rating_w * daily_operating_hours / 1000
    estimated_annual_consumption_kwh = estimated_daily_consumption_kwh * 365

Both are stored read-only (computed server-side here) so a client cannot
spoof them.
"""

import frappe
from frappe import _
from frappe.model.document import Document

HOURS_IN_DAY = 24
DAYS_IN_YEAR = 365


class Device(Document):
	def validate(self):
		self.validate_operating_hours()
		self.compute_consumption()

	def validate_operating_hours(self):
		"""Guard the 0-24 range and reject negatives.

		`non_negative` on the doctype fields already blocks negatives at the
		framework level, but daily_operating_hours additionally has a real
		upper bound (a day has 24 hours), which no field property enforces.
		"""
		hours = self.daily_operating_hours
		if hours in (None, ""):
			self.daily_operating_hours = 0
			return

		try:
			hours = float(hours)
		except (TypeError, ValueError):
			frappe.throw(_("Daily Operating Hours must be a number."))

		if hours < 0:
			frappe.throw(_("Daily Operating Hours cannot be negative."))
		if hours > HOURS_IN_DAY:
			frappe.throw(
				_("Daily Operating Hours cannot exceed {0} (a day has only 24 hours).").format(
					HOURS_IN_DAY
				)
			)

	def compute_consumption(self):
		"""Derive the read-only consumption estimates from the scalar fields.

		Empty/None numeric fields are coerced to 0 so a partially-filled device
		never raises (a device may legitimately have no power data recorded).
		"""
		rating = _as_float(self.power_rating_w)
		hours = _as_float(self.daily_operating_hours)

		daily = round(rating * hours / 1000.0, 4)
		self.estimated_daily_consumption_kwh = daily
		self.estimated_annual_consumption_kwh = round(daily * DAYS_IN_YEAR, 4)

		# Surface a likely data-entry mistake instead of silently computing a
		# nonsense estimate: standby draw above the rated operating draw.
		if _as_float(self.standby_power_w) > rating and rating > 0:
			frappe.msgprint(
				_(
					"Standby Power ({0} W) is higher than the Power Rating ({1} W). "
					"Please double-check these values."
				).format(self.standby_power_w, self.power_rating_w),
				indicator="orange",
				alert=True,
			)


def _as_float(value):
	"""Coerce a possibly-None/blank form value to float, defaulting to 0.0."""
	if value in (None, ""):
		return 0.0
	try:
		return float(value)
	except (TypeError, ValueError):
		return 0.0
PYEOF

echo "== writing device.js =="
cat > "$DT_DIR/device.js" <<'JSEOF'
// Device — live preview of the server-side consumption estimate.
//
// The authoritative calculation lives in device.py::compute_consumption and is
// recomputed on every save; this only keeps the read-only fields in sync while
// the user is still typing, so the form isn't misleading before a save.

frappe.ui.form.on("Device", {
	refresh(frm) {
		calculate_consumption(frm);
	},

	power_rating_w(frm) {
		calculate_consumption(frm);
	},

	daily_operating_hours(frm) {
		calculate_consumption(frm);
	},

	validate(frm) {
		// Mirror the server's hard bound so the user gets immediate feedback
		// instead of a round-trip error.
		const hours = flt(frm.doc.daily_operating_hours);
		if (hours < 0 || hours > 24) {
			frappe.validated = false;
			frappe.msgprint(__("Daily Operating Hours must be between 0 and 24."));
		}
	},
});

function calculate_consumption(frm) {
	const rating = flt(frm.doc.power_rating_w);
	const hours = flt(frm.doc.daily_operating_hours);
	const daily = rating * hours / 1000.0;

	frm.set_value("estimated_daily_consumption_kwh", flt(daily, null, 4));
	frm.set_value("estimated_annual_consumption_kwh", flt(daily * 365, null, 4));
}
JSEOF

echo "== writing __init__.py =="
touch "$DT_DIR/__init__.py"

echo "== test file (real assertions, not a stub) =="
cat > "$DT_DIR/test_device.py" <<'TESTEOF'
# -*- coding: utf-8 -*-
"""Tests for the Device doctype's power-consumption calculations."""

import frappe
from frappe.tests.utils import FrappeTestCase


class TestDevice(FrappeTestCase):
	def make_device(self, **kwargs):
		doc = frappe.get_doc(
			{
				"doctype": "Device",
				"device_name": "Test Device",
				"device_type": "Robot",
				"status": "Active",
				**kwargs,
			}
		)
		return doc

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
TESTEOF

echo "== doctype files written =="
find "$DT_DIR" -type f | sort

echo
echo "== copying back to host source of truth dir =="
mkdir -p /tmp/device-doctype-out
cp -r "$DT_DIR/." /tmp/device-doctype-out/
echo "copied to /tmp/device-doctype-out"
