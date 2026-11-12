/* Tracked Item list — show each unit's QR and barcode as thumbnails. */
frappe.listview_settings['Tracked Item'] = {
	add_fields: [
		'qr_image', 'barcode_image', 'item_qr_image',
		'item_barcode', 'serial_no', 'item_code', 'current_status'
	],
	formatters: {
		qr_image: (value) => value
			? '<img src="' + value + '" style="height:44px;width:44px;object-fit:contain;">'
			: '',
		barcode_image: (value) => value
			? '<img src="' + value + '" style="height:26px;max-width:110px;object-fit:contain;">'
			: '',
	}
};
