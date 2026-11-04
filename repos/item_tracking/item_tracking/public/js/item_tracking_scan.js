/* Individual Item Tracking — scan popup + Stock Entry wiring.
 * Loaded app-wide via app_include_js so the popup is available on any page. */
frappe.provide('item_tracking');

item_tracking.lookup = function (value) {
	return frappe.call({
		method: 'item_tracking.item_tracking.api.lookup_tracked_item',
		args: { search_value: value }
	});
};

/* Build the serial-number + status-history table shown in the popup. */
item_tracking._history_table = function (history) {
	if (!history || !history.length) { return ''; }
	const rows = history.map(function (h) {
		return '<tr>'
			+ '<td>' + frappe.utils.escape_html(h.transaction_type || '') + '</td>'
			+ '<td>' + frappe.utils.escape_html(h.transaction_reference || '') + '</td>'
			+ '<td>' + frappe.utils.escape_html(h.previous_warehouse || '') + '</td>'
			+ '<td>' + frappe.utils.escape_html(h.new_warehouse || '') + '</td>'
			+ '<td>' + frappe.utils.escape_html(h.movement_date || '') + '</td>'
			+ '</tr>';
	}).join('');
	return '<p><b>' + __('Status History') + ':</b></p>'
		+ '<table class="table table-bordered table-condensed" style="font-size: 12px; margin-bottom: 0;">'
		+ '<thead><tr><th>' + __('Type') + '</th><th>' + __('Reference') + '</th>'
		+ '<th>' + __('From') + '</th><th>' + __('To') + '</th><th>' + __('Date') + '</th></tr></thead>'
		+ '<tbody>' + rows + '</tbody></table>';
};

/* Show the popup: Product Name, Serial No, Unique ID, Current Location + status table. */
item_tracking.show_popup = function (data) {
	if (!data || (!data.tracking_id && !data.is_item)) {
		frappe.msgprint({
			title: __('Item not found'),
			indicator: 'red',
			message: __('No item or tracked item matches that QR code, barcode, or ID.')
		});
		return;
	}

	// Item-level (SKU barcode / item code) result: show the item + stock summary.
	if (data.is_item) {
		const id = new frappe.ui.Dialog({
			title: __('Item in Stock'),
			fields: [
				{ fieldtype: 'HTML', fieldname: 'body',
				  options: '<h4>' + frappe.utils.escape_html(data.item_name || '') + '</h4>'
					+ '<p><b>' + __('Item Code') + ':</b> ' + frappe.utils.escape_html(data.item_code) + '</p>'
					+ '<p><b>' + __('Stock on hand') + ':</b> ' + frappe.utils.escape_html(data.stock_qty) + '</p>'
					+ '<p><b>' + __('Tracked Units') + ':</b> ' + frappe.utils.escape_html(data.tracked_count) + '</p>' }
			],
			primary_action_label: __('Open Item'),
			primary_action: function () {
				frappe.set_route('Form', 'Item', data.item_code);
				id.hide();
			}
		});
		id.show();
		return;
	}
	const loc = data.current_warehouse || data.current_status || __('Unknown');
	const transit = data.in_transit
		? '<span class="text-muted">(' + __('{0} — outside warehouse', [data.current_status]) + ')</span>'
		: '';
	const serial = data.serial_no
		? '<p><b>' + __('Serial No') + ':</b> ' + frappe.utils.escape_html(data.serial_no) + '</p>'
		: '';
	const d = new frappe.ui.Dialog({
		title: __('Tracked Item'),
		fields: [
			{ fieldtype: 'HTML', fieldname: 'body',
			  options: '<h4>' + frappe.utils.escape_html(data.item_name || '') + '</h4>'
			  	+ '<p><b>' + __('Unique ID') + ':</b> ' + frappe.utils.escape_html(data.tracking_id) + '</p>'
			  	+ serial
			  	+ '<p><b>' + __('Current Status') + ':</b> ' + frappe.utils.escape_html(data.current_status || __('Unknown')) + '</p>'
			  	+ '<p><b>' + __('Current Location') + ':</b> ' + frappe.utils.escape_html(loc) + ' ' + transit + '</p>'
			  	+ item_tracking._history_table(data.status_history) }
		],
		primary_action_label: __('Open Tracked Item'),
		primary_action: function () {
			frappe.set_route('Form', 'Tracked Item', data.tracking_id);
			d.hide();
		}
	});
	d.show();
};

/* Manual/camera/USB scan entry: prompt, resolve, popup. */
item_tracking.scan = function () {
	frappe.prompt(
		[{ fieldname: 'code', fieldtype: 'Data', label: __('Scan or enter Tracking ID / Barcode'), reqd: 1 }],
		function (values) {
			item_tracking.lookup(values.code).then(function (r) {
				item_tracking.show_popup(r.message);
			});
		},
		__('Scan Tracked Item'),
		__('Look Up')
	);
};

/* Lazily load jsQR as a QR fallback for browsers without native BarcodeDetector
 * (Safari/Firefox). Loaded on demand — only when the camera scanner starts and no
 * native detector exists — so it never weighs down ordinary pages. */
item_tracking._load_jsqr = function () {
	if (window.jsQR || item_tracking._jsqr_requested) { return; }
	item_tracking._jsqr_requested = true;
	const s = document.createElement('script');
	s.src = 'https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js';
	s.async = true;
	document.head.appendChild(s);
};

/* Inline camera scanner: activate the camera INSIDE a Desk dialog (no navigation,
 * no separate window), decode QR/barcode frames with the native BarcodeDetector,
 * falling back to jsQR when it is unavailable, resolve the tracking_id, and show
 * the popup. Repeated scans keep working. */
item_tracking.scan_camera = function () {
	let stream = null;
	let detector = null;
	let scanning = true;
	let rafId = null;
	let lastValue = null;
	let lastTime = 0;
	let scanCanvas = null;
	let scanCtx = null;

	function stop() {
		scanning = false;
		if (rafId) { cancelAnimationFrame(rafId); rafId = null; }
		if (stream) { stream.getTracks().forEach(function (t) { t.stop(); }); stream = null; }
	}

	function handle(value) {
		value = (value || '').trim();
		if (!value) { return; }
		// Debounce so a single code held in view fires once; a different code
		// (or the same one re-presented after 2.5s) still resolves immediately.
		const now = Date.now();
		if (value === lastValue && now - lastTime < 2500) { return; }
		lastValue = value;
		lastTime = now;
		item_tracking.lookup(value).then(function (r) {
			item_tracking.show_popup(r.message);
		});
	}

	function tick() {
		const video = document.getElementById('it-scan-video');
		if (!scanning) { return; }
		if (video && video.videoWidth) {
			if (detector) {
				detector.detect(video).then(function (codes) {
					if (codes && codes.length) { handle(codes[0].rawValue); }
				}).catch(function () { /* ignore per-frame decode errors */ });
			} else if (window.jsQR) {
				// jsQR fallback for browsers without native BarcodeDetector
				// (Safari/Firefox): draw the frame to a canvas and decode the QR.
				try {
					if (!scanCanvas) {
						scanCanvas = document.createElement('canvas');
						scanCtx = scanCanvas.getContext('2d', { willReadFrequently: true });
					}
					const maxDim = 640;
					const w = video.videoWidth, h = video.videoHeight;
					const scale = Math.min(1, maxDim / Math.max(w, h));
					const cw = Math.max(1, Math.floor(w * scale));
					const ch = Math.max(1, Math.floor(h * scale));
					if (scanCanvas.width !== cw) { scanCanvas.width = cw; }
					if (scanCanvas.height !== ch) { scanCanvas.height = ch; }
					scanCtx.drawImage(video, 0, 0, cw, ch);
					const img = scanCtx.getImageData(0, 0, cw, ch);
					const code = window.jsQR(img.data, cw, ch, { inversionAttempts: 'dontInvert' });
					if (code && code.data) { handle(code.data); }
				} catch (e) { /* ignore per-frame decode errors */ }
			}
		}
		rafId = requestAnimationFrame(tick);
	}

	const d = new frappe.ui.Dialog({
		title: __('Scan Tracked Item'),
		fields: [
			{
				fieldtype: 'HTML',
				fieldname: 'view',
				options: '<div style="text-align:center;">'
					+ '<video id="it-scan-video" autoplay playsinline muted '
					+ 'style="width:100%;max-width:480px;border-radius:8px;background:#000;"></video>'
					+ '<p class="text-muted" style="margin-top:10px;">'
					+ __('Point the camera at the item QR code or barcode') + '</p>'
					+ '</div>'
			}
		],
		primary_action_label: __('Done'),
		primary_action: function () { stop(); d.hide(); }
	});

	d.onhide = function () { stop(); };
	d.show();

	if ('BarcodeDetector' in window) {
		try {
			detector = new BarcodeDetector({
				formats: ['qr_code', 'code_128', 'code_39', 'ean_13', 'ean_8']
			});
		} catch (e) { detector = null; }
	}

	if (!detector) { item_tracking._load_jsqr(); }

	navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } })
		.then(function (s) {
			stream = s;
			const video = document.getElementById('it-scan-video');
			video.srcObject = s;
			video.onloadedmetadata = function () { video.play(); };
			rafId = requestAnimationFrame(tick);
		})
		.catch(function () {
			d.hide();
			frappe.msgprint({
				title: __('Camera unavailable'),
				indicator: 'orange',
				message: __('Camera access was denied or is unavailable. Falling back to manual entry.')
			});
			item_tracking.scan();
		});
};

/* Stock Entry integration: resolve scan, add item row + tracked_items row,
 * reject duplicates. Location is NOT changed here — only on submit. */
item_tracking.scan_into_stock_entry = function (frm) {
	frappe.prompt(
		[{ fieldname: 'code', fieldtype: 'Data', label: __('Scan or enter Tracking ID / Barcode'), reqd: 1 }],
		function (values) {
			item_tracking.lookup(values.code).then(function (r) {
				const data = r.message || {};
				if (!data.tracking_id) {
					frappe.msgprint({ title: __('Item not found'), indicator: 'red' });
					return;
				}
				// Duplicate prevention (spec Test 8).
				const already = (frm.doc.tracked_items || []).some(function (t) {
					return t.tracked_item === data.tracking_id;
				});
				if (already) {
					frappe.msgprint({ title: __('Already scanned'),
						message: __('{0} is already in this Stock Entry.', [data.tracking_id]),
						indicator: 'orange' });
					return;
				}
				// Add the individual item association.
				const row = frm.add_child('tracked_items', {
					tracked_item: data.tracking_id,
					item_code: data.item_code,
					item_name: data.item_name,
					scanned_warehouse: data.current_warehouse
				});
				// Add/mirror the ERPNext item row so stock validation runs normally.
				// Stock Entry item rows need s_warehouse/t_warehouse from the header
				// (Material Receipt -> t_warehouse, Material Issue -> s_warehouse,
				// Material Transfer -> both); without them ERPNext rejects the row on
				// save/submit with a missing-warehouse error.
				const exists = frm.doc.items.find(function (i) { return i.item_code === data.item_code; });
				if (!exists) {
					const it = frm.add_child('items', {
						item_code: data.item_code,
						qty: 1,
						s_warehouse: frm.doc.from_warehouse || null,
						t_warehouse: frm.doc.to_warehouse || null,
						allow_zero_valuation_rate: 1
					});
					frm.script_manager.trigger('item_code', it.doctype, it.name);
				} else {
					exists.qty = (exists.qty || 0) + 1;
				}
				frm.refresh_field('tracked_items');
				frm.refresh_field('items');
				item_tracking.show_popup(data);
			});
		},
		__('Scan Tracked Item'),
		__('Add to Stock Entry')
	);
};

/* Global hot-path: expose a Desk "Scan Item" shortcut (Shift+I).
 * Registered unconditionally — `frappe.ui.keys` is part of the core desk bundle,
 * so it is always present when app_include_js runs. (A previous `if
 * (frappe.ui.toolbar)` guard referenced a symbol that does not exist in Frappe
 * v16, so the shortcut never registered.) */
frappe.ui.keys.add_shortcut({
	shortcut: 'shift+i',
	action: function () { item_tracking.scan_camera(); },
	description: __('Scan Tracked Item'),
});
