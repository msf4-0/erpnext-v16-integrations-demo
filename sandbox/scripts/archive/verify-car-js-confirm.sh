#!/usr/bin/env bash
# Prove the client-side confirm-before-save logic behaves correctly WITHOUT a
# browser click, by running car.js itself in Node against a fake `frappe`
# harness. This tests the real handler code (not a re-implementation):
#   A. no workshops              -> handler returns undefined, save proceeds
#   B. all workshops Active      -> handler returns a resolved promise, no dialog
#   C. an Inactive workshop      -> confirm IS shown; "Yes" -> save proceeds;
#                                   "No"  -> frappe.validated=false (save aborts)
#   D. the promise is AWAITED    -> the harness proves the returned value is a
#                                   thenable, which is what gates the save chain
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

JS=apps/car_tracker/car_tracker/car_tracker/doctype/car/car.js
mkdir -p /tmp/carjs
cp "$JS" /tmp/carjs/car.js

cat > /tmp/carjs/harness.js <<'NODEEOF'
// Minimal stand-ins for the frappe globals car.js touches at load+call time.
const handlers = {};
global.frappe = {
	ui: { form: { on: (doctype, obj) => Object.assign(handlers, obj) } },
	db: {
		get_list: (doctype, args) => {
			global.__last_query = { doctype, args };
			return Promise.resolve(global.__inactive_rows || []);
		},
	},
	confirm: (msg, on_yes, on_no) => {
		global.__confirm_msg = msg;
		global.__confirm = { on_yes, on_no };
	},
	validated: true,
	utils: { escape_html: (s) => s },
	datetime: {
		add_months: () => "2027-01-01",
		get_today: () => "2026-09-18",
		str_to_obj: (s) => new Date(s),
		get_diff: () => 100,
	},
};
global.__ = (s, args) => (args ? s.replace("{0}", args[0]) : s);
global.flt = (v) => parseFloat(v) || 0;
global.cur_frm = null;
global.refresh_field = () => {};

require("/tmp/carjs/car.js");

function make_frm(rows) {
	return {
		doc: { service_records: rows, last_recorded_mileage: 1000 },
		set_value: () => {},
	};
}

async function run() {
	const validate = handlers["validate"];
	const results = [];
	const record = (label, got, want) =>
		results.push([label, String(got), String(want), String(got) === String(want) ? "OK" : "MISMATCH"]);

	// A. no workshops at all
	global.__inactive_rows = [];
	frappe.validated = true;
	let r = validate(make_frm([{ service_type: "Oil Change", service_date: "2026-08-01" }]));
	record("A_no_ws_returns_undefined", r === undefined, true);

	// B. all active -> query returns no inactive rows; promise resolves, no dialog
	global.__inactive_rows = [];
	global.__confirm_msg = null;
	r = validate(make_frm([{ service_type: "Oil Change", workshop: "WS-1" }]));
	record("B_returns_thenable", r && typeof r.then === "function", true);
	await r;
	record("B_no_dialog_shown", global.__confirm_msg === null, true);
	record("B_validated_still_true", frappe.validated, true);

	// C1. inactive + user clicks YES -> dialog shown, validated stays true
	global.__inactive_rows = [{ name: "WS-INACTIVE" }];
	global.__confirm_msg = null;
	frappe.validated = true;
	r = validate(make_frm([{ service_type: "Oil Change", workshop: "WS-INACTIVE" }]));
	const p = r;
	await Promise.resolve(); // let the get_list promise resolve and show confirm
	record("C1_dialog_shown", !!global.__confirm_msg, true);
	record("C1_mentions_inactive", /inactive/i.test(global.__confirm_msg || ""), true);
	global.__confirm.on_yes();
	await p;
	record("C1_yes_keeps_validated", frappe.validated, true);

	// C2. inactive + user clicks NO -> validated cleared (save aborts)
	global.__inactive_rows = [{ name: "WS-INACTIVE" }];
	global.__confirm_msg = null;
	frappe.validated = true;
	r = validate(make_frm([{ service_type: "Oil Change", workshop: "WS-INACTIVE" }]));
	const p2 = r;
	await Promise.resolve();
	global.__confirm.on_no();
	await p2;
	record("C2_no_clears_validated", frappe.validated, false);

	// D. the query used the right doctype + Inactive filter
	record("D_queries_Car_Workshop", global.__last_query.doctype, "Car Workshop");
	record("D_filter_inactive", JSON.stringify(global.__last_query.args.filters), JSON.stringify({
		name: ["in", ["WS-INACTIVE"]], status: "Inactive",
	}));

	let fails = 0;
	console.log("=== CAR.JS CONFIRM-BEFORE-SAVE LOGIC ===");
	for (const [label, got, want, ok] of results) {
		console.log(`${label.padEnd(28)} | got=${got.padEnd(18)} | want=${want.padEnd(18)} | ${ok}`);
		if (ok !== "OK") fails++;
	}
	console.log("FAILURES:", fails);
	process.exit(fails ? 1 : 0);
}

run();
NODEEOF

node /tmp/carjs/harness.js
