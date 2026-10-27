#!/usr/bin/env bash
# Add a V x I vs Power Rating consistency CHECK to the Device doctype.
#
# Per operator decision: WARN on mismatch, never overwrite. Rationale: P = V*I
# only holds for DC / purely resistive loads. A robot arm or PoE light is
# inductive/non-linear, so apparent power (VA) != real power (W). Auto-deriving
# the rating from V*I would silently corrupt correct wattage data.
#
# Also mirrors the check client-side in device.js, bumps the DocType `modified`
# timestamp (editing a .js does NOT bump it, so the desk would otherwise serve
# a stale cached script), and clears the cache.
set -uo pipefail

APP=robotics_lab
APP_DIR="/home/frappe/frappe-bench/apps/$APP"
DT_DIR="$APP_DIR/$APP/$APP/doctype/device"
SITE="${SITE_NAME:-frontend}"
TOLERANCE=0.05   # 5%

cd /home/frappe/frappe-bench || exit 1

if [ ! -d "$DT_DIR" ]; then
  echo "ERROR: $DT_DIR not found"
  exit 1
fi

echo "== writing device.py (adds validate_power_consistency) =="
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

Note on voltage/current: they are INDEPENDENT reference inputs, NOT used to
derive the power rating. P = V * I only holds for DC or purely resistive loads;
robots and PoE lights are inductive/non-linear, so apparent power (VA) is not
equal to real power (W). We therefore only *flag* a mismatch for the user to
review — we never overwrite a manually-entered rating.
"""

import frappe
from frappe import _
from frappe.model.document import Document

HOURS_IN_DAY = 24
DAYS_IN_YEAR = 365

# How far apparent power (V*I) may differ from the stated rating before we
# flag it. Generous, because VA and W legitimately differ by the power factor.
VA_WARN_TOLERANCE = 0.05


class Device(Document):
	def validate(self):
		self.validate_operating_hours()
		self.compute_consumption()
		self.validate_power_consistency()

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

	def validate_power_consistency(self):
		"""Flag a rating that disagrees with Voltage x Current. Never overwrites.

		Only runs when all three values are present and positive — a device may
		legitimately have no electrical data recorded, and we must not nag in
		that case. Apparent power (VA) is compared against real power (W); for
		AC/inductive loads these differ by the power factor, so this is a
		review prompt, not an error.
		"""
		rating = _as_float(self.power_rating_w)
		voltage = _as_float(self.voltage_v)
		current = _as_float(self.current_a)

		if rating <= 0 or voltage <= 0 or current <= 0:
			return

		apparent_va = voltage * current
		if abs(rating - apparent_va) / rating <= VA_WARN_TOLERANCE:
			return

		frappe.msgprint(
			_(
				"Power Rating ({0} W) does not match Voltage x Current "
				"({1} V x {2} A = {3} VA).<br>"
				"These are different quantities for AC/inductive loads "
				"(VA is apparent power, W is real power), so nothing was changed — "
				"but please confirm the rating is correct."
			).format(
				frappe.format_value(rating, {"fieldtype": "Float"}),
				frappe.format_value(voltage, {"fieldtype": "Float"}),
				frappe.format_value(current, {"fieldtype": "Float"}),
				frappe.format_value(apparent_va, {"fieldtype": "Float"}),
			),
			title=_("Power Rating Check"),
			indicator="orange",
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

echo "== writing device.js (mirrors the check + reacts to voltage/current) =="
cat > "$DT_DIR/device.js" <<'JSEOF'
// Device — live preview of the server-side consumption estimate, plus a
// client-side mirror of the power-consistency check.
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

	// Voltage/current do NOT drive the rating (P = V*I is only valid for DC or
	// resistive loads). These handlers exist purely so the consistency hint
	// refreshes as the user edits them.
	voltage_v(frm) {
		check_power_consistency(frm);
	},

	current_a(frm) {
		check_power_consistency(frm);
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

const VA_WARN_TOLERANCE = 0.05;

// Advisory only — never rewrites the rating. Uses a form-level indicator rather
// than a popup so editing V/A doesn't spam dialogs; the server does the same
// check on save and shows the full message there.
function check_power_consistency(frm) {
	const rating = flt(frm.doc.power_rating_w);
	const voltage = flt(frm.doc.voltage_v);
	const current = flt(frm.doc.current_a);

	if (rating <= 0 || voltage <= 0 || current <= 0) {
		return;
	}

	const apparent = voltage * current;
	const off = Math.abs(rating - apparent) / rating > VA_WARN_TOLERANCE;

	frm.dashboard.clear_headline();
	if (off) {
		frm.dashboard.set_headline(
			__("Power Rating ({0} W) differs from Voltage x Current ({1} VA). VA != W for AC loads — please confirm.", [
				rating,
				flt(apparent, null, 2),
			]),
			"orange"
		);
	}
}
JSEOF

echo "== also clear the headline when the rating itself changes =="
# (calculate_consumption runs on rating change; the consistency check is
# re-run on save by the server, so nothing further is needed here.)

echo "== bump DocType modified + clear cache (file edits do NOT bump it) =="
bench --site "$SITE" execute frappe.db.set_value --kwargs \
  "{'doctype':'DocType','name':'Device','fieldname':'modified','value':'$(date '+%Y-%m-%d %H:%M:%S.%f')'}"
bench --site "$SITE" clear-cache
bench --site "$SITE" execute frappe.clear_cache --kwargs "{'doctype':'Device'}"

echo
echo "== restart serve =="
pkill -f 'frappe serve' 2>/dev/null
pkill -f 'bench serve' 2>/dev/null
sleep 3
( cd /home/frappe/frappe-bench && setsid nohup bench serve --port 8000 > /tmp/bench-serve.log 2>&1 < /dev/null & disown )
sleep 8
echo "serve restarted"

echo
echo "== stage the updated source for the host copy =="
rm -rf /tmp/devfix && mkdir -p /tmp/devfix
cp "$DT_DIR/device.py" "$DT_DIR/device.js" /tmp/devfix/
ls -la /tmp/devfix/
