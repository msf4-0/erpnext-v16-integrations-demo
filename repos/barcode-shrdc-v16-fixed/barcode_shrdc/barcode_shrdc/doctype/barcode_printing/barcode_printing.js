// Copyright (c) 2021, lxy and contributors
// For license information, please see license.txt

frappe.ui.form.on('Barcode Printing', {
	setup: function(frm){
		frm.set_value("show_sku",0);
		frm.set_value("show_serial_no",0);
		frm.set_value("show_batch_no",0);
	},
	load_tracked_items: function(frm) {
		frappe.prompt([
			{ fieldname: 'item_code', fieldtype: 'Link', options: 'Item', label: __('Item (leave blank for all)'), reqd: 0 }
		], function (values) {
			frappe.call({
				method: 'barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.make_tracked_item_qrcodes',
				args: { item_code: (values && values.item_code) || null },
				freeze: true,
				callback: function(r) {
					if (r.exc) {
						frappe.msgprint({ title: __('QR Code Generation Failed'), indicator: 'red', message: r.exc });
						return;
					}
					const field = frm.fields_dict['qrcodes'];
					if (field && field.$wrapper) {
						field.$wrapper.html(r.message || '');
					}
					if (!r.message || r.message.indexOf('<img') === -1) {
						frappe.msgprint({ title: __('No Tracked Items'), indicator: 'orange', message: __('No Tracked Items found for that item.') });
					}
				}
			});
		}, __('Load Tracked Items'), __('Load'));
	},
	refresh: function(frm) {
		frm.add_custom_button(__('Serial Numbers'), function() {
			let row = null;
			const grid = frm.fields_dict.items && frm.fields_dict.items.grid;
			if (grid && grid.get_selected_children) {
				const selected = grid.get_selected_children();
				if (selected && selected.length) row = selected[0];
			}
			if (!row) {
				row = (frm.doc.items || []).find(r => r.item_code);
			}
			if (!row) {
				frappe.msgprint(__("Add an item row first."));
				return;
			}
			frm.events.open_serial_dialog(frm, row.doctype, row.name);
		});

		frm.add_custom_button(__('Purchase Receipt'), function() {
			erpnext.utils.map_current_doc({
				method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.pr_make_barcode",
				source_doctype: "Purchase Receipt",
				target: frm,
				date_field: "posting_date",
				setters: {
					supplier: frm.doc.supplier || undefined,
				},
				get_query_filters: {
					docstatus: 1
				}
			})

		}, __("Get items from"));

		frm.add_custom_button(__('Stock Entry'), function() {
			erpnext.utils.map_current_doc({
				method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.se_make_barcode",
				source_doctype: "Stock Entry",
				target: frm,
				date_field: "posting_date",
				setters: {
					stock_entry_type: frm.doc.stock_entry_type,
				},
				get_query_filters: {
					docstatus: 1
				}
			})


		}, __("Get items from"));

		frm.add_custom_button(__('Material Receipt'), function() {
			erpnext.utils.map_current_doc({
				method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.se_make_barcode",
				source_doctype: "Stock Entry",
				target: frm,
				date_field: "posting_date",
				get_query_filters: {
					docstatus: 1,
					stock_entry_type: "Material Receipt"
				}
			})
		}, __("Get items from"));

		frm.add_custom_button(__('Material Request'), function() {
			erpnext.utils.map_current_doc({
				method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.mr_make_barcode",
				source_doctype: "Material Request",
				target: frm,
				date_field: "transaction_date",
				get_query_filters: {
					docstatus: 1
				}
			})
		}, __("Get items from"));

		frm.add_custom_button(__('Purchase Order'), function() {
			erpnext.utils.map_current_doc({
				method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.po_make_barcode",
				source_doctype: "Purchase Order",
				target: frm,
				date_field: "transaction_date",
				setters: {
					supplier: frm.doc.supplier || undefined,
				},
				get_query_filters: {
					docstatus: 1
				}
			})
		}, __("Get items from"));

		frm.add_custom_button(__('Load Tracked Items'), function() {
			frm.trigger('load_tracked_items');
		}, __("Get items from"));

		// Print the QR preview: opens a clean print window containing only the
		// QR labels so each unit's QR can be printed on its own label.
		frm.add_custom_button(__('Print QR Codes'), function() {
			const field = frm.fields_dict['qrcodes'];
			const html = (field && field.$wrapper && field.$wrapper.html()) || '';
			if (!html || html.trim() === '') {
				frappe.msgprint({
					title: __('Nothing to print'),
					indicator: 'orange',
					message: __('Generate QR codes first (Get QR Code or Load Tracked Items).')
				});
				return;
			}
			const w = window.open('', '_blank', 'width=900,height=700');
			if (!w) {
				frappe.msgprint({ title: __('Popup blocked'), indicator: 'red',
					message: __('Allow popups for this site to print QR labels.') });
				return;
			}
			w.document.write(
				'<html><head><title>QR Codes</title>'
				+ '<style>'
				+ 'body{font-family:sans-serif;padding:16px;}'
				+ '.qr-card{display:inline-block;margin:12px;text-align:center;border:1px solid #eee;padding:8px;page-break-inside:avoid;}'
				+ '.qr-card img{width:180px;}'
				+ '@media print{.qr-card{border:1px dashed #999;}}'
				+ '</style></head><body>'
				+ html
				+ '<script>window.onload=function(){window.print();}<\/script>'
				+ '</body></html>'
			);
			w.document.close();
		});
	},
	validate: function(frm)
	{
		for(let item of frm.doc.items)
		{
			if (item.serial_no && typeof item.serial_no === "string")
			{
				var serial_numbers = item.serial_no.split("\n");
					if (serial_numbers[serial_numbers.length-1]=='')
					{
						serial_numbers.pop();
					}
				console.log(serial_numbers);
				var qty = item.qty;
				if (serial_numbers.length != qty || qty ==0)
				{
					frappe.validated = false;
					frappe.msgprint({
						title: __('Warning'),
						indicator: 'red',
						message: __('{0}: serial no. does not match the number of qty.',[item.item_code]),
					});
				}
			}


		
		}


	},
	get_barcode: function(frm)
	{
		// One click: every row gets its own unique serial number (existing ones
		// reused first, missing ones created), and the barcode mirrors it.
		const rows = (frm.doc.items || []).filter(d => d.item_code);
		if (!rows.length) {
			frappe.msgprint(__("Add at least one item first."));
			return;
		}

		let used = [];
		let created_total = 0;

		const finish = () => {
			frm.refresh_field("items");
			if (created_total) {
				frappe.show_alert({
					message: __("{0} new serial number(s) created.", [created_total]),
					indicator: "green"
				}, 7);
			}
		};

		const next = (i) => {
			if (i >= rows.length) {
				finish();
				return;
			}
			const d = rows[i];
			const qty = Math.max(1, Math.floor(flt(d.qty) || 1));

			frappe.call({
				method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.ensure_serials",
				args: {
					item_code: d.item_code,
					qty: qty,
					warehouse: d.s_warehouse || d.t_warehouse || "",
					exclude: used
				},
				freeze: true,
				freeze_message: __("Preparing serial numbers for {0}...", [d.item_code]),
				callback: (r) => {
					const res = r.message || {};
					const serials = res.serials || [];
					created_total += cint(res.created || 0);

					const values = {};
					if (serials.length) {
						used = used.concat(serials);
						values.serial_no = res.serials_text;
						values.qty = serials.length;
						values.barcode = serials[0];
						values.barcode_type = "CODE128";
					}
					if (Object.keys(values).length) {
						frappe.model.set_value(d.doctype, d.name, values);
					}
					next(i + 1);
				},
				error: () => next(i + 1)
			});
		};

		next(0);
	},
	show_sku: function(frm) {
		frm.trigger("show_sku_barcode");
	},
	show_batch_no: function(frm) {
		frm.trigger("show_batch_no_barcode");
	},
	batch_barcode_type: function(frm) {
		frm.trigger("show_batch_no_barcode");
	},
	show_serial_no: function(frm) {
		frm.trigger("show_serial_no_barcode");
	},
	serial_barcode_type: function(frm) {
		frm.trigger("show_serial_no_barcode");
	},
	create_qr: function(frm)
	{
		var route = window.location.origin;
		frappe.call({
			method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.make_qrcode",
			args: {
				doc: frm.doc,
				route: route
			},
			callback: function(r) {
				if (r.exc) {
					frappe.msgprint({
						title: __("QR Code Generation Failed"),
						indicator: "red",
						message: r.exc
					});
					return;
				}
				frm.set_value("qr_created", 1);
				var field = frm.fields_dict["qrcodes"];
				if (field && field.$wrapper) {
					field.$wrapper.html(r.message || "");
				}
			}
		});

	},
	show_sku_barcode: function(frm) {
		if(frm.doc.show_sku)
		{
			// Server-side preview (no CDN / client-side JsBarcode needed).
			frappe.call({
				method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_preview_html",
				args: {doc: frm.doc, kind: "sku"},
				callback: function(r) {
					$(frm.fields_dict['barcodes'].$wrapper).html(r.message || "")
						.css({"margin-left": "20px", "margin-top": "10px", "font-family": "monospace"});
				}
			});
		}
	},
	show_serial_barcode: function(frm) {
		if(frm.doc.show_serial_no)
		{
			// Server-side preview (no CDN / client-side JsBarcode needed).
			frappe.call({
				method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_preview_html",
				args: {doc: frm.doc, kind: "serial"},
				callback: function(r) {
					$(frm.fields_dict['serials'].$wrapper).html(r.message || "")
						.css({"margin-left": "20px", "margin-top": "10px", "font-family": "monospace"});
				}
			});
		}
	},
	show_batch_barcode: function(frm) {
		if(frm.doc.show_batch_no)
		{
			// Server-side preview (no CDN / client-side JsBarcode needed).
			frappe.call({
				method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_preview_html",
				args: {doc: frm.doc, kind: "batch"},
				callback: function(r) {
					$(frm.fields_dict['batchs'].$wrapper).html(r.message || "")
						.css({"margin-left": "20px", "margin-top": "10px", "font-family": "monospace"});
				}
			});
		}
	},
	set_serial_no: function(frm, cdt, cdn, callback) {
		var d = frappe.model.get_doc(cdt, cdn);
		if(!d.item_code && !d.s_warehouse && !d.qty) return;
		var	args = {
			'item_code'	: d.item_code,
			'warehouse'	: cstr(d.s_warehouse),
			'stock_qty'		: d.transfer_qty
		};
		frappe.call({
			// ERPNext v16's erpnext.stock.get_item_details.get_serial_no is a
			// stub: it requires a single `_args` payload and returns [].
			method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_serial_no",
			args: args,
			callback: function(r) {
				// Only accept a real string so `validate` never calls .split()
				// on an array.
				if (!r.exe && r.message && typeof r.message === "string") {
					frappe.model.set_value(cdt, cdn, "serial_no", r.message);

					if (callback) {
						callback();
					}
				} else if (!r.exe && d.has_serial_no) {
					frappe.show_alert({
						message: __("No available serial numbers for {0} ({1}). Create them via a Purchase Receipt or Stock Entry first.",
							[d.item_code, d.s_warehouse || __("any warehouse")]),
						indicator: "orange"
					}, 7);
				}
			}
		});
	},
	// Ask the user whether to reuse existing serial numbers or mint new ones.
	set_serial_no_choice: function(frm, cdt, cdn) {
		const d = locals[cdt][cdn];
		if (!d.item_code) return;

		frappe.db.get_value("Item", d.item_code, ["has_serial_no", "has_batch_no"]).then((r) => {
			const info = r.message || {};
			d.has_serial_no = info.has_serial_no;
			d.has_batch_no = info.has_batch_no;

			if (info.has_batch_no && !info.has_serial_no) {
				// Batch-only items keep using ERPNext's batch selector.
				erpnext.stock.select_batch_and_serial_no(frm, d);
				return;
			}
			if (!info.has_serial_no) return;
			frm.events.open_serial_dialog(frm, cdt, cdn);
		});
	},

	open_serial_dialog: function(frm, cdt, cdn) {
		const d = locals[cdt][cdn];
		if (!d.item_code) {
			frappe.msgprint(__("Select an item first."));
			return;
		}

		const warehouse = d.s_warehouse || d.t_warehouse || "";

		frappe.call({
			method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_serial_summary",
			args: { item_code: d.item_code, warehouse: warehouse },
			callback: (r) => {
				const summary = r.message || {};
				if (!summary.item_code) return;

				const existing = summary.existing || [];
				const qty = flt(d.qty) || existing.length || 1;
				const scope = warehouse || __("stock");

				const dlg = new frappe.ui.Dialog({
					title: __("Serial Numbers — {0}", [d.item_code]),
					fields: [
						{
							fieldtype: "HTML",
							fieldname: "summary",
							options: `<p class="text-muted" style="margin-bottom:10px">${
								existing.length
									? __("{0} existing serial number(s) available in {1}.", [existing.length, scope])
									: __("No serial numbers exist yet for this item.")
							}</p>`,
						},
						{
							fieldname: "qty",
							fieldtype: "Int",
							label: __("Quantity"),
							reqd: 1,
							default: qty,
							description: __("How many serial numbers to use or create"),
						},
					],
					primary_action_label: __("Create new serial numbers"),
					primary_action(values) {
						dlg.hide();
						frm.events.create_item_serials(frm, cdt, cdn, values.qty);
					},
				});

				dlg.set_secondary_action(__("Use existing ({0})", [existing.length]), () => {
					const values = dlg.get_values();
					dlg.hide();
					frm.events.use_existing_serials(frm, cdt, cdn, values.qty);
				});

				dlg.show();
			},
		});
	},

	use_existing_serials: function(frm, cdt, cdn, qty) {
		const d = locals[cdt][cdn];
		frappe.call({
			method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_serial_no",
			args: {
				item_code: d.item_code,
				warehouse: d.s_warehouse || d.t_warehouse || "",
				stock_qty: qty,
			},
			callback: (r) => {
				const text = (r.message || "").trim();
				if (!text) {
					frappe.msgprint(
						__("No existing serial numbers were found for {0}. Use “Create new serial numbers” instead.", [d.item_code])
					);
					return;
				}
				frappe.model.set_value(cdt, cdn, {
					serial_no: text,
					qty: text.split("\n").length,
				});
			},
		});
	},

	create_item_serials: function(frm, cdt, cdn, qty) {
		const d = locals[cdt][cdn];
		frappe.call({
			method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.create_serials",
			args: {
				item_code: d.item_code,
				qty: qty,
				warehouse: d.s_warehouse || d.t_warehouse || "",
			},
			freeze: true,
			freeze_message: __("Creating serial numbers…"),
			callback: (r) => {
				const res = r.message || {};
				if (!res.serials || !res.serials.length) return;
				frappe.show_alert(
					{
						message: __("{0} serial number(s) created ({1}).", [res.serials.length, res.stock_entry]),
						indicator: "green",
					},
					7
				);
				frappe.model.set_value(cdt, cdn, {
					serial_no: res.serials_text,
					qty: res.serials.length,
				});
				if (res.tracked && res.tracked.length) {
					frm.dirty();
				}
			},
		});
	},

	set_basic_rate: function(frm, cdt, cdn) {
		const item = locals[cdt][cdn];
		item.transfer_qty = flt(item.qty) * flt(item.conversion_factor);

		const args = {
			'item_code'			: item.item_code,
			'posting_date'		: frm.doc.posting_date,
			'posting_time'		: frm.doc.posting_time,
			'warehouse'			: cstr(item.s_warehouse) || cstr(item.t_warehouse),
			'serial_no'			: item.serial_no,
			'company'			: frm.doc.company,
			'qty'				: item.s_warehouse ? -1*flt(item.transfer_qty) : flt(item.transfer_qty),
			'voucher_type'		: frm.doc.doctype,
			'voucher_no'		: item.name,
			'allow_zero_valuation': 1,
		};

		if (item.item_code || item.serial_no) {
			frappe.call({
				method: "erpnext.stock.utils.get_incoming_rate",
				args: {
					args: args
				},
				callback: function(r) {
					frappe.model.set_value(cdt, cdn, 'basic_rate', (r.message || 0.0));
				}
			});
		}
	},
	// v16 removed the erpnext.setup_serial_no API; the serial/batch selector is
	// opened per-item via erpnext.stock.select_batch_and_serial_no below.
});

frappe.ui.form.on('Barcode Generator Items', {
	qty: function(frm, cdt, cdn) {
		frm.events.set_serial_no(frm, cdt, cdn, () => {
			frm.events.set_basic_rate(frm, cdt, cdn);
		});
	},

	conversion_factor: function(frm, cdt, cdn) {
		frm.events.set_basic_rate(frm, cdt, cdn);
	},

	s_warehouse: function(frm, cdt, cdn) {
		frm.events.set_serial_no(frm, cdt, cdn, () => {
			frm.events.get_warehouse_details(frm, cdt, cdn);
		});
	},

	t_warehouse: function(frm, cdt, cdn) {
		frm.events.get_warehouse_details(frm, cdt, cdn);
	},

	barcode: function(doc, cdt, cdn) {
		frm.set_value("qr_created",0);
		frm.set_value("show_sku",0);

		var d = locals[cdt][cdn];
		if (d.barcode) {
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
		}
	},

	uom: function(doc, cdt, cdn) {
		var d = locals[cdt][cdn];
		if(d.uom && d.item_code){
			return frappe.call({
				method: "erpnext.stock.doctype.stock_entry.stock_entry.get_uom_details",
				args: {
					item_code: d.item_code,
					uom: d.uom,
					qty: d.qty
				},
				callback: function(r) {
					if(r.message) {
						frappe.model.set_value(cdt, cdn, r.message);
					}
				}
			});
		}
	},
	serial_no(frm){
		frm.set_value("qr_created",0);
		frm.set_value("show_serial_no",0);
	},
	batch_no(frm){
		frm.set_value("qr_created",0);
		frm.set_value("show_batch_no",0);
	},
	items_add: function(frm){
		frm.set_value("qr_created",0);
		frm.set_value("show_sku",0);
		frm.set_value("show_serial_no",0);
		frm.set_value("show_batch_no",0);

	},
	items_remove:function(frm){
		frm.set_value("qr_created",0);
		frm.set_value("show_sku",0);
		frm.set_value("show_serial_no",0);
		frm.set_value("show_batch_no",0);

	},
	item_code: function(frm, cdt, cdn) {
		frm.set_value("qr_created",0);
		frm.set_value("show_sku",0);
		frm.set_value("show_serial_no",0);
		frm.set_value("show_batch_no",0);
		var d = locals[cdt][cdn];
		if(d.item_code) {
			var args = {
				'item_code'			: d.item_code,
				'warehouse'			: cstr(d.s_warehouse) || cstr(d.t_warehouse),
				'serial_no'		: d.serial_no,
				'bom_no'		: d.bom_no,
				'expense_account'	: d.expense_account,
				'cost_center'		: d.cost_center,
				'company'		: frm.doc.company,
				'qty'			: d.qty,
				'voucher_type'		: frm.doc.doctype,
				'voucher_no'		: d.name,
				'allow_zero_valuation': 1,
			};

			return frappe.call({
				doc: frm.doc,
				method: "get_item_details",
				args: args,
				callback: function(r) {
					if(r.message) {
						var d = locals[cdt][cdn];
						$.each(r.message, function(k, v) {
							if (v) {
								frappe.model.set_value(cdt, cdn, k, v); // qty and it's subsequent fields weren't triggered
							}
						});
						frm.refresh_field("items");

						if (!d.serial_no) {
							frm.events.set_serial_no_choice(frm, cdt, cdn);
						}
					}
				}
			});
		}
	}
});

$.extend(cur_frm.cscript, new erpnext.stock.StockController({frm: cur_frm}));

erpnext.stock.select_batch_and_serial_no = (frm, item) => {
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
