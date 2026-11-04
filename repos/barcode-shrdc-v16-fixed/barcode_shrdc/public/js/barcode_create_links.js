// barcode_shrdc — connect the source documents to Barcode Printing through the
// top-right "Create" menu so the flow
//
//     Material Receipt (Stock Entry) / Purchase Receipt
//         -> Purchase Order
//         -> Barcode Printing
//
// is one click away. Each source form gets a "Create > Barcode Printing" action
// that pulls the document's items into a new Barcode Printing record (same
// server-side mappers the "Get items from" buttons on Barcode Printing use).

frappe.ui.form.on("Purchase Order", {
	refresh: function (frm) {
		if (frm.is_new()) return;
		frm.add_custom_button(
			__("Barcode Printing"),
			function () {
				frappe.model.open_mapped_doc({
					method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.po_make_barcode",
					frm: frm,
				});
			},
			__("Create")
		);
	},
});

frappe.ui.form.on("Purchase Receipt", {
	refresh: function (frm) {
		if (frm.is_new()) return;
		frm.add_custom_button(
			__("Barcode Printing"),
			function () {
				frappe.model.open_mapped_doc({
					method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.pr_make_barcode",
					frm: frm,
				});
			},
			__("Create")
		);
	},
});

frappe.ui.form.on("Stock Entry", {
	refresh: function (frm) {
		// "Material Receipt" is a Stock Entry with stock_entry_type == "Material Receipt".
		if (frm.is_new()) return;
		frm.add_custom_button(
			__("Barcode Printing"),
			function () {
				frappe.model.open_mapped_doc({
					method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.se_make_barcode",
					frm: frm,
				});
			},
			__("Create")
		);

		// Link back to the Purchase Receipt(s): open the linked receipt when one is
		// recorded on this Stock Entry, otherwise open the Purchase Receipt list.
		frm.add_custom_button(
			__("Purchase Receipt"),
			function () {
				if (frm.doc.purchase_receipt_no) {
					frappe.set_route("Form", "Purchase Receipt", frm.doc.purchase_receipt_no);
				} else {
					frappe.set_route("List", "Purchase Receipt");
				}
			},
			__("Create")
		);
	},
});

frappe.ui.form.on("Material Request", {
	refresh: function (frm) {
		if (frm.is_new()) return;
		frm.add_custom_button(
			__("Barcode Printing"),
			function () {
				frappe.model.open_mapped_doc({
					method: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.mr_make_barcode",
					frm: frm,
				});
			},
			__("Create")
		);
	},
});
