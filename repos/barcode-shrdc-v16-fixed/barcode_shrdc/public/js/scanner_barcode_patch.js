// barcode_shrdc — extend Frappe's built-in camera scanner so it decodes 1D
// linear barcodes (Code128/EAN/UPC/Code39/etc.) in addition to QR codes.
//
// Frappe's scanner (`frappe/public/js/frappe/scanner/index.js`) calls
// `Html5Qrcode.start()` with no `formatsToSupport`, so html5-qrcode defaults to
// QR-only — which is why the camera only reads QR and not barcodes. This patch
// adds the 1D formats and retitles the misleading "Scan QRCode" dialog.
frappe.provide("barcode_shrdc.scanner");

(function () {
	function scan_config() {
		const cfg = { fps: 10, qrbox: 250 };
		const F = window.Html5QrcodeSupportedFormats;
		if (F) {
			cfg.formatsToSupport = [
				F.QR_CODE,
				F.CODE_128,
				F.CODE_39,
				F.CODE_93,
				F.CODABAR,
				F.EAN_13,
				F.EAN_8,
				F.UPC_A,
				F.UPC_E,
				F.ITF,
			];
		}
		return cfg;
	}

	function patch() {
		if (!window.frappe || !frappe.ui || !frappe.ui.Scanner) return false;
		if (frappe.ui.Scanner.__barcode_shrdc_patched) return true;

		const OrigStartScan = frappe.ui.Scanner.prototype.start_scan;
		frappe.ui.Scanner.prototype.start_scan = function () {
			if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
				return OrigStartScan.call(this);
			}
			if (!this.handler) {
				this.handler = new Html5Qrcode(this.scan_area_id); // eslint-disable-line
			}
			this.stop_requested = false;
			this.handler
				.start(
					{ facingMode: "environment" },
					scan_config(),
					(decodedText, decodedResult) => this.on_scan_success(decodedText, decodedResult),
					() => {}
				)
				.then(() => {
					this.is_alive = true;
					if (this.stop_requested) {
						this.stop_scan();
						return;
					}
					this.setup_enhancements();
				})
				.catch((err) => {
					this.is_alive = false;
					this.show_error(err);
				});
		};

		// Retitle the misleading "Scan QRCode" dialog to reflect 1D + QR.
		const OrigMakeDialog = frappe.ui.Scanner.prototype.make_dialog;
		frappe.ui.Scanner.prototype.make_dialog = function () {
			const dlg = OrigMakeDialog.call(this);
			try {
				const t = dlg && dlg.$wrapper && dlg.$wrapper.find(".modal-title");
				if (t && t.length) t.text(__("Scan Barcode / QR"));
			} catch (e) {
				/* cosmetic */
			}
			return dlg;
		};

		frappe.ui.Scanner.__barcode_shrdc_patched = true;
		return true;
	}

	if (!patch()) {
		let tries = 0;
		const timer = setInterval(() => {
			if (patch() || ++tries > 120) clearInterval(timer);
		}, 500);
	}
})();
