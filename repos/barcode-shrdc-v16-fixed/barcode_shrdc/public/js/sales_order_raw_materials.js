// barcode_shrdc — make Sales Order "Create > Request for Raw Materials" land on
// the Material Request it just created, instead of leaving a bare message popup.
//
// Everything else (the item picker dialog, the server-side mapping, submitting
// the request) is the stock ERPNext behaviour; only the post-create step changes.

frappe.ui.form.on("Sales Order", {
	refresh(frm) {
		if (frm.__raw_material_request_patched) return;

		// Patch the FORM INSTANCE, not frm.events.
		//
		// Core ERPNext does:  this.make_raw_material_request_dialog(r)
		// inside make_raw_material_request(), where `this` is the form /
		// controller object.  An own-property on `frm` shadows the prototype
		// method, so this is the assignment that actually takes effect.
		//
		// The previous version only replaced frm.events.make_raw_material_request_dialog.
		// That object is not what the controller resolves the call through, so the
		// core method kept running and its confirmation
		// (frappe.msgprint(__("Material Request {0} submitted.", [...]))) rendered
		// as an empty "Message" dialog with no link.  Patching both the instance
		// and frm.events keeps this working whichever path Frappe resolves.
		const patched = function (r) {
			open_raw_material_dialog(frm, r);
		};
		frm.make_raw_material_request_dialog = patched;
		if (frm.events) {
			frm.events.make_raw_material_request_dialog = patched;
		}
		frm.__raw_material_request_patched = true;
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
						// Land directly on the Material Request that was just
						// created - the items to purchase are on that document.
						frappe.show_alert({
							message: __("Material Request {0} created", [message.name]),
							indicator: "green",
						});
						frappe.set_route("Form", "Material Request", message.name);
					} else {
						// Nothing left to request (server returned no document).
						// Say so instead of leaving an empty message box.
						frappe.show_alert({
							message: __(
								"No new Material Request was created - these items are already covered by existing requests."
							),
							indicator: "orange",
						});
						frappe.set_route("List", "Material Request");
					}
				},
			});
		},
		primary_action_label: __("Create"),
	});

	dialog.show();
}
