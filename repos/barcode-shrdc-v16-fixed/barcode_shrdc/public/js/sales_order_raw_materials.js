// barcode_shrdc — make Sales Order "Create > Request for Raw Materials" land on
// the Material Request it just created, instead of leaving a bare message popup.
//
// Everything else (the item picker dialog, the server-side mapping, submitting
// the request) is the stock ERPNext behaviour; only the post-create step changes.

frappe.ui.form.on("Sales Order", {
	refresh(frm) {
		// Where does the method actually live?
		//
		// Frappe's ScriptManager does:
		//     this.frm.cscript = extend_cscript(frm.cscript, new ControllerClass({frm}))
		// and the Sales Order controller registers the button as
		//     () => this.make_raw_material_request()
		// where `this` is that controller instance (it reads `this.frm`).
		// So the call `this.make_raw_material_request_dialog(r)` resolves on
		// frm.cscript - NOT on frm.events (where the previous version put it)
		// and not on the form object itself.
		//
		// Rather than bet on one owner, shadow the method on every object that
		// could be on that resolution path.  Re-applied on each refresh because
		// it is cheap and idempotent, and because a form reload rebuilds cscript.
		const patched = function (r) {
			open_raw_material_dialog(frm, r);
		};
		// Marker so the installation is checkable from the browser console:
		//   cur_frm.cscript.make_raw_material_request_dialog.__rm_patched
		// -> true means the override is live on this form.
		patched.__rm_patched = true;

		let installed = false;
		for (const owner of [frm.cscript, frm.events, frm]) {
			if (owner && typeof owner.make_raw_material_request_dialog === "function") {
				owner.make_raw_material_request_dialog = patched;
				installed = true;
			}
		}
		// If nothing matched yet, leave it: the next refresh retries.  (The old
		// version set a "patched" flag and could stop trying for good.)
		return installed;
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
