// barcode_shrdc — make Sales Order "Create > Request for Raw Materials" land on
// the Material Request it just created, instead of leaving a bare message popup.
//
// Everything else (the item picker dialog, the server-side mapping, submitting
// the request) is the stock ERPNext behaviour; only the post-create step changes.

frappe.ui.form.on("Sales Order", {
	refresh(frm) {
		const events = frm.events || frm;
		if (events.__raw_material_request_patched) return;
		if (typeof events.make_raw_material_request_dialog !== "function") return;

		// The core handlers live on the form's events object and are called as
		// `this.make_raw_material_request_dialog(...)`, so replacing it here is
		// enough to change what happens after the request is created.
		events.make_raw_material_request_dialog = function (r) {
			open_raw_material_dialog(frm, r);
		};
		events.__raw_material_request_patched = true;
	},
});

function open_raw_material_dialog(frm, r) {
	r.message.forEach((item) => (item.__checked = 1));

	const fields = [
		{
			fieldtype: "Check",
			fieldname: "include_exploded_items",
			label: __("Include Exploded Items"),
		},
		{
			fieldtype: "Check",
			fieldname: "ignore_existing_ordered_qty",
			label: __("Ignore Existing Ordered Qty"),
		},
		{
			fieldtype: "Table",
			fieldname: "items",
			description: __("Finished Goods"),
			cannot_delete_rows: true,
			fields: [
				{
					fieldtype: "Read Only",
					fieldname: "item_code",
					label: __("Item Code"),
					in_list_view: 1,
				},
				{
					fieldtype: "Link",
					fieldname: "warehouse",
					options: "Warehouse",
					label: __("For Warehouse"),
					in_list_view: 1,
				},
				{
					fieldtype: "Link",
					fieldname: "bom",
					options: "BOM",
					reqd: 1,
					label: __("BOM"),
					in_list_view: 1,
					get_query: function (doc) {
						return { filters: { item: doc.item_code } };
					},
				},
				{
					fieldtype: "Float",
					fieldname: "required_qty",
					reqd: 1,
					label: __("Qty"),
					in_list_view: 1,
				},
			],
			data: r.message,
			get_data: function () {
				return r.message;
			},
		},
	];

	const dialog = new frappe.ui.Dialog({
		title: __("Items for Raw Material Request"),
		fields: fields,
		primary_action() {
			const data = dialog.get_values();
			frm.call({
				method: "erpnext.selling.doctype.sales_order.sales_order.make_raw_material_request",
				args: {
					items: data,
					company: frm.doc.company,
					sales_order: frm.docname,
					project: frm.doc.project,
				},
				freeze: true,
				freeze_message: __("Creating the Material Request..."),
				callback(res) {
					dialog.hide();
					const message = res.message;
					if (message && message.name) {
						frappe.set_route("Form", "Material Request", message.name);
					} else {
						// Nothing left to request: go to the requests already raised
						// for this order instead of showing an empty message box.
						frappe.set_route("List", "Material Request", {
							sales_order: frm.docname,
						});
					}
				},
			});
		},
		primary_action_label: __("Create"),
	});

	dialog.show();
}
