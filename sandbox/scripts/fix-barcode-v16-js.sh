#!/usr/bin/env bash
# Fix barcode_shrdc on ERPNext v16 — form JS side.
#
# Symptoms:
#   - saving a form with a serial row crashed:
#       TypeError: item.serial_no.split is not a function
#     because v16's erpnext.stock.get_item_details.get_serial_no is a stub that
#     returns [] (an array) and the callback wrote that truthy value into the
#     serial_no field, then `validate` called .split() on it.
#   - `erpnext.setup_serial_no()` (items_on_form_rendered) and
#     `erpnext.SerialNoBatchSelector` no longer exist on v16 (replaced by
#     erpnext.SerialBatchPackageSelector) -> JS errors.
#   - typing a barcode called erpnext.stock.get_item_details.get_item_code,
#     which v16 no longer whitelists -> HTTP 403 "not whitelisted".
#     v16's whitelisted replacement is erpnext.stock.utils.scan_barcode.
#
# All edits are idempotent (marker-based).
set -uo pipefail
JS=/home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.js

echo "== before =="
grep -n "serial_no.split\|setup_serial_no\|SerialNoBatchSelector\|get_item_code\|select_batch_and_serial_no" "$JS" || true

python3 - "$JS" <<'PYEOF'
import io, sys

path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()
changes = []

# ---------------------------------------------------------------- 1. validate
old = """	validate: function(frm)
	{
		for(let item of frm.doc.items)
		{
			if (item.serial_no)
			{"""
new = """	validate: function(frm)
	{
		for(let item of frm.doc.items)
		{
			if (item.serial_no && typeof item.serial_no === "string")
			{"""
if "if (item.serial_no && typeof item.serial_no === \"string\")" in src:
    changes.append("validate: already guarded")
elif old in src:
    src = src.replace(old, new, 1); changes.append("validate: guarded")
else:
    changes.append("validate: MARKER NOT FOUND")

# ---------------------------------------------------------- 2. set_serial_no
old = """			callback: function(r) {
				if (!r.exe && r.message) {
					frappe.model.set_value(cdt, cdn, "serial_no", r.message);

					if (callback) {
						callback();
					}
				}
			}"""
new = """			callback: function(r) {
				// v16 get_serial_no returns [] (an array); only accept a real
				// string so `validate` never calls .split() on an array.
				if (!r.exe && r.message && typeof r.message === "string") {
					frappe.model.set_value(cdt, cdn, "serial_no", r.message);

					if (callback) {
						callback();
					}
				}
			}"""
if 'typeof r.message === "string"' in src:
    changes.append("set_serial_no: already guarded")
elif old in src:
    src = src.replace(old, new, 1); changes.append("set_serial_no: guarded")
else:
    changes.append("set_serial_no: MARKER NOT FOUND")

# ------------------------------------------- 3. serial display loop (render)
old = """					if (serials && barcode_format)
					{
						serials = serials.split("\\n");
						if (serials[serials.length-1]=='')
						{
							serials.pop();
						}
						for(const serial of serials)
						{
							sku_content += '<div class="label-item-barcode label-field">';"""
new = """					if (serials && barcode_format && typeof serials === "string")
					{
						serials = serials.split("\\n");
						if (serials[serials.length-1]=='')
						{
							serials.pop();
						}
						for(const serial of serials)
						{
							sku_content += '<div class="label-item-barcode label-field">';"""
if 'if (serials && barcode_format && typeof serials === "string")' in src:
    changes.append("serial render loop: already guarded")
elif old in src:
    src = src.replace(old, new, 1); changes.append("serial render loop: guarded")
else:
    changes.append("serial render loop: MARKER NOT FOUND")

# ------------------------------------- 4. serial display loop (JsBarcode call)
old = """					var serials = item.serial_no;
					if (serials && barcode_format)
					{"""
new = """					var serials = item.serial_no;
					if (serials && barcode_format && typeof serials === "string")
					{"""
if old in src:
    src = src.replace(old, new, 1); changes.append("serial barcode loop: guarded")
elif "if (serials && barcode_format && typeof serials === \"string\")" in src:
    changes.append("serial barcode loop: already guarded")
else:
    changes.append("serial barcode loop: MARKER NOT FOUND")

# ------------------------------------------------- 5. dead setup_serial_no()
old = """	items_on_form_rendered: function(doc, grid_row) {
		erpnext.setup_serial_no();
	},

});"""
new = """	// v16 removed the erpnext.setup_serial_no API; the serial/batch selector is
	// opened per-item via erpnext.stock.select_batch_and_serial_no below.
});"""
if "items_on_form_rendered" not in src:
    changes.append("setup_serial_no: already removed")
elif old in src:
    src = src.replace(old, new, 1); changes.append("setup_serial_no: removed")
else:
    changes.append("setup_serial_no: MARKER NOT FOUND (call present but block differs)")

# ------------------------------------------- 6. barcode -> item_code lookup
old = """		if (d.barcode) {
			frappe.call({
				method: "erpnext.stock.get_item_details.get_item_code",
				args: {"barcode": d.barcode },
				callback: function(r) {
					if (!r.exe){
						frappe.model.set_value(cdt, cdn, "item_code", r.message);
					}
				}
			});
		}"""
new = """		if (d.barcode) {
			// v16 no longer whitelists erpnext.stock.get_item_details.get_item_code;
			// the whitelisted equivalent is erpnext.stock.utils.scan_barcode.
			frappe.call({
				method: "erpnext.stock.utils.scan_barcode",
				args: {search_value: d.barcode },
				callback: function(r) {
					if (!r.exe && r.message && r.message.item_code) {
						frappe.model.set_value(cdt, cdn, "item_code", r.message.item_code);
					}
				}
			});
		}"""
if "erpnext.stock.utils.scan_barcode" in src:
    changes.append("barcode lookup: already v16")
elif old in src:
    src = src.replace(old, new, 1); changes.append("barcode lookup: -> scan_barcode")
else:
    changes.append("barcode lookup: MARKER NOT FOUND")

# ------------------------------- 7. global select_batch_and_serial_no override
start = "erpnext.stock.select_batch_and_serial_no = (frm, item) => {"
if start in src:
    idx = src.index(start)
    tail = """erpnext.stock.select_batch_and_serial_no = (frm, item) => {
	let get_warehouse_type_and_name = (item) => {
		let value = '';
		if (item.s_warehouse) {
			value = cstr(item.s_warehouse) || '';
			return {type: 'Source Warehouse', name: value};
		} else {
			value = cstr(item.t_warehouse) || '';
			return {type: 'Target Warehouse', name: value};
		}
	}

	if (item && !item.has_serial_no && !item.has_batch_no) return;
	if (frm.doc.purpose === 'Material Receipt') return;

	frappe.require("assets/erpnext/js/utils/serial_no_batch_selector.js", function() {
		// v16 renamed SerialNoBatchSelector -> SerialBatchPackageSelector and
		// expects a callback (it writes serial_and_batch_bundle back onto the row).
		if (!frappe.model.can_read("Item")) return;
		frappe.db.get_value("Item", item.item_code, ["has_batch_no", "has_serial_no"]).then((r) => {
			if (r.message && (r.message.has_batch_no || r.message.has_serial_no)) {
				item.has_serial_no = r.message.has_serial_no;
				item.has_batch_no = r.message.has_batch_no;
				item.type_of_transaction = item.s_warehouse ? "Outward" : "Inward";
				new erpnext.SerialBatchPackageSelector(frm, item, (res) => {
					if (!res) return;
					// The child doctype (Barcode Generator Items) has serial_no /
					// batch_no but NOT the serial_and_batch_bundle fields, so only
					// write back fields the row actually has.
					let updates = {};
					if (frappe.meta.has_field(item.doctype, "serial_and_batch_bundle")) {
						updates.serial_and_batch_bundle = res.name;
						updates.use_serial_batch_fields = 0;
					}
					if (res.avg_rate) updates.basic_rate = res.avg_rate;
					if (res.total_qty) {
						updates.qty = Math.abs(res.total_qty) / flt(item.conversion_factor || 1);
					}
					if (Object.keys(updates).length) {
						frappe.model.set_value(item.doctype, item.name, updates);
					}
				});
			}
		});
	});
}
"""
    src = src[:idx] + tail
    changes.append("select_batch_and_serial_no: v16 override")
else:
    changes.append("select_batch_and_serial_no: already replaced / absent")

io.open(path, "w", encoding="utf-8").write(src)
for c in changes:
    print("  " + c)
PYEOF

echo
echo "== after =="
grep -n "serial_no.split\|typeof item.serial_no\|typeof r.message\|typeof serials\|setup_serial_no\|SerialBatchPackageSelector\|scan_barcode" "$JS" || true
