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
							const item_qr = frm.doc.item_qr_image || '';
							const item_bc = frm.doc.item_barcode || '';
							const cell = (img, label, extra) =>
								'<div style="text-align:center;margin:8px 18px;display:inline-block;vertical-align:top;">'
								+ (img ? '<img src="' + img + '" ' + (extra || 'width="180px"') + '/><br>' : '')
								+ '<span class="text-muted">' + label + '</span></div>';

							field.$wrapper.html(
								'<div style="display:flex;flex-wrap:wrap;justify-content:center;">'
								+ cell(qr, __('Unit QR') + ' (' + (frm.doc.serial_no || tracking_id) + ')')
								+ cell(barcode, __('Unit Barcode'), 'style="max-width:220px;"')
								+ cell(item_qr, __('Item QR') + ' (' + (frm.doc.item_code || '') + ')')
								+ (item_bc
									? '<div style="text-align:center;margin:8px 18px;display:inline-block;">'
										+ '<div style="font-family:monospace;font-size:13px;padding:10px 6px;">'
										+ frappe.utils.escape_html(item_bc) + '</div>'
										+ '<span class="text-muted">' + __('Item Barcode') + '</span></div>'
									: '')
								+ '</div>'
							);
						}
					}
				});
			}
		});
	}
});
