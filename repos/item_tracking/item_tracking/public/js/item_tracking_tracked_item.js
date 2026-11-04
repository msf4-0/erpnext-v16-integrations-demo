/* Tracked Item form — render this unit's own QR code and barcode images. */
frappe.ui.form.on('Tracked Item', {
	refresh: function (frm) {
		if (frm.is_new()) { return; }
		const tracking_id = frm.doc.name || frm.doc.tracking_id;
		if (!tracking_id) { return; }

		frappe.call({
			method: 'item_tracking.item_tracking.doctype.tracked_item.tracked_item.get_tracking_qr_image',
			args: { tracking_id: tracking_id },
			callback: function (r) {
				const qr = r.message || '';
				frappe.call({
					method: 'item_tracking.item_tracking.doctype.tracked_item.tracked_item.get_tracking_barcode_image',
					args: { tracking_id: tracking_id },
					callback: function (r2) {
						const barcode = r2.message || '';
						const field = frm.fields_dict['qr_barcode_preview'];
						if (field && field.$wrapper) {
							field.$wrapper.html(
								(qr ? '<div style="text-align:center;margin-bottom:12px;">'
									+ '<img src="' + qr + '" width="180px"/><br>'
									+ '<span class="text-muted">' + __('QR Code') + '</span></div>' : '')
								+ (barcode ? '<div style="text-align:center;">'
									+ '<img src="' + barcode + '" style="max-width:100%;"/><br>'
									+ '<span class="text-muted">' + __('Barcode') + '</span></div>' : '')
							);
						}
					}
				});
			}
		});
	}
});
