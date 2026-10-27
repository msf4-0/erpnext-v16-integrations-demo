#!/usr/bin/env bash
# Fix barcode_shrdc on ERPNext v16 — Python side.
#
# Symptom set (reproduced authenticated over HTTP, see
# sandbox/scripts/verify-barcode-newdoc-v16.sh):
#   1. "Create QR" on a NEW (unsaved) doc -> 404
#        DoesNotExistError: Barcode Printing new-... not found
#   2. the whitelisted MODULE-level get_item_details(frm) -> 500
#        AttributeError: 'dict' object has no attribute 'doc'
#      (invalid SQL: `where i.parent=%s` on tabItem Barcode)
#   3. make_qrcode embedded `data:image/png;base64,...` URIs, which frappe's
#      print/PDF pipeline does not reliably render, so printed QRs were blank.
#
# Fixes:
#   - friendly ValidationError when "Create QR" is used before saving
#   - module-level get_item_details: valid parameterized SQL, tolerant of a
#     parsed-dict or JSON-string `frm`, returns {} instead of raising
#   - make_qrcode/qr_code_img: save each QR as a PUBLIC PNG file and reference
#     it by URL (no data URI)
#   - new whitelisted get_barcode_image() + get_qr_image() (server-side
#     renderers for the print formats) and their _save_public_image() helper
#
# Idempotent: re-running is a no-op once the markers are present.
set -uo pipefail
F=/home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.py

echo "== before: relevant defs =="
grep -n "def get_item_details\|def make_qrcode\|def qr_code_img\|def get_barcode_image\|def get_qr_image\|_save_public_image" "$F" || true

python3 - "$F" <<'PYEOF'
import io, re, sys

path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()

# ------------------------------------------------- class method whitelist
# The form fetches item details with frappe.call({doc: frm.doc, method:
# "get_item_details"}), which goes through frappe.handler.run_doc_method. Since
# v15 run_doc_method enforces is_whitelisted() on the controller method, and
# upstream master's *class* method has no decorator (only the unused module-level
# function does), every item_code fetch failed 403 "... is not whitelisted".
CLASS_MARKER = "\tdef get_item_details(self, args=None, for_update=False):"
if "\t@frappe.whitelist()\n" + CLASS_MARKER in src:
	print("  class get_item_details: already whitelisted")
elif CLASS_MARKER in src:
	src = src.replace(CLASS_MARKER, "\t@frappe.whitelist()\n" + CLASS_MARKER, 1)
	print("  class get_item_details: @frappe.whitelist() ADDED")
else:
	print("  class get_item_details: MARKER NOT FOUND — aborting")
	sys.exit(1)

# ---------------------------------------------------------------- module fn
NEW_MODULE_GET_ITEM_DETAILS = '''@frappe.whitelist()
def get_item_details(frm):
	"""Return {barcode, barcode_type} for the first item of a Barcode Printing
	form. Kept for backward compatibility; the form itself uses the whitelisted
	*class* method of the same name via run_doc_method."""
	try:
		frm = frappe.parse_json(frm) if isinstance(frm, str) else frm
	except Exception:
		frm = {}
	frm = frm or {}
	doc = frm.get("doc") or frm
	items = doc.get("items") or []
	item_code = doc.get("item_code") or next(
		(d.get("item_code") for d in items if d.get("item_code")), None
	)
	if not item_code:
		return {}
	item = frappe.db.get_value(
		"Item Barcode", {"parent": item_code}, ["barcode", "barcode_type"], as_dict=True
	)
	return item or {}
'''

pat_mod = re.compile(r"@frappe\.whitelist\(\)\ndef get_item_details\(frm\):.*?\n\treturn item\n", re.S)
if "def get_item_details(frm):" not in src:
	print("  module-level get_item_details: ALREADY REPLACED (marker absent)")
elif "frappe.parse_json(frm) if isinstance(frm, str)" in src:
	print("  module-level get_item_details: ALREADY PATCHED")
else:
	src, n = pat_mod.subn(NEW_MODULE_GET_ITEM_DETAILS, src, count=1)
	assert n == 1, "module-level get_item_details marker found but not replaced"
	print("  module-level get_item_details: PATCHED")

# ------------------------------------------------- make_qrcode ... EOF tail
NEW_TAIL = '''@frappe.whitelist()
def make_qrcode(doc, route):
	qr_html = ''
	docinfo = json.loads(doc) if isinstance(doc, str) else doc
	docname = (docinfo or {}).get("name")
	# A brand-new, unsaved document has a temp name ("new-barcode-printing-..."),
	# so there is nothing to fetch yet: give a friendly message instead of a raw
	# DoesNotExistError.
	if not docname or str(docname).startswith("new-") or not frappe.db.exists("Barcode Printing", docname):
		frappe.throw(_("Please save the document before generating QR codes"), frappe.ValidationError)

	barcode_doc = frappe.get_doc("Barcode Printing", docname)
	items = barcode_doc.items
	for item in items:
		if item.get("qty")!= 0:
			if item.get("serial_no") and isinstance(item.get("serial_no"), str):
				serials = item.get("serial_no").split("\\n")
				if serials[-1] == '':
					serials.pop()
				for serial in serials:
					uri  = "item_qr?"
					if item.get("item_code"): uri += "item_code=" + urllib.parse.quote(item.get_formatted("item_code")) 
					if item.get("barcode"): uri += "&barcode=" + urllib.parse.quote(item.get_formatted("barcode")) 
					if serial: uri += "&serial_no=" + urllib.parse.quote(serial) 
					if item.get("batch_no"): uri += "&batch_no=" + urllib.parse.quote(item.get_formatted("batch_no")) 
					img_url = qr_code_img(uri, route)
					qr_html += '<img src="' + img_url + '" width="240px"/><br>'
			else:
				uri  = "item_qr?"
				if item.get("item_code"): uri += "item_code=" + urllib.parse.quote(item.get_formatted("item_code")) 
				if item.get("barcode"): uri += "&barcode=" + urllib.parse.quote(item.get_formatted("barcode")) 
				if item.get("batch_no"): uri += "&batch_no=" + urllib.parse.quote(item.get_formatted("batch_no")) 
				img_url = qr_code_img(uri, route)
				qr_html += '<img src="' + img_url + '" width="240px"/><br>'
	return qr_html


def qr_code_img(uri, route):
	qr_config = frappe.get_doc("QR Code Configuration")
	qr = qrcode.QRCode(
		border=qr_config.border,
		error_correction=qrcode.constants.ERROR_CORRECT_H,
	)
	url = route + "/" + uri
	qr.add_data(url)
	qr.make(fit=True)
	logo = qr_config.logo

	img = qr.make_image(fill_color = qr_config.fill, back_color = qr_config.background)
	w,h = img.size
	if logo:
		logo = Image.open(requests.get(get_url(logo,None), stream=True).raw).resize((w//4, h//4))
		pos = ((img.size[0] - logo.size[0]) // 2, (img.size[1] - logo.size[1]) // 2)
		img.paste(logo, pos)

	buffered = BytesIO()
	img.save(buffered, format="PNG")
	# Save as a public File and return its URL: frappe's print/PDF pipeline does
	# not reliably render `data:image/...;base64,...` URIs.
	return _save_public_image(buffered.getvalue(), "qr")


@frappe.whitelist()
def get_barcode_image(barcode, barcode_type=None, width=None, height=None, display_value=None, docname=None):
	"""Render a linear barcode server-side to a public PNG so the print/PDF
	pipeline can show it (the old <svg> + CDN JsBarcode approach renders blank)."""
	from reportlab.graphics.barcode import createBarcodeDrawing

	barcode_type = (barcode_type or "CODE128").upper()
	# reportlab uses its own names for a few formats
	rl_map = {
		"EAN": "EAN13",
		"UPC": "UPCA",
		"UPC-A": "UPCA",
		"CODE39": "Code39",
		"CODE128": "Code128",
		"EAN13": "EAN13",
		"EAN8": "EAN8",
	}
	rl_type = rl_map.get(barcode_type, barcode_type)

	bar_kwargs = {
		"value": cstr(barcode),
		"barHeight": flt(height) or 40,
		"barWidth": flt(width) or 2,
		"humanReadable": cint(display_value) == 1,
	}
	try:
		drawing = createBarcodeDrawing(rl_type, **bar_kwargs)
	except Exception:
		# fall back to a plain Code128 for unsupported formats
		drawing = createBarcodeDrawing("Code128", **bar_kwargs)

	return _save_public_image(drawing.asString("png"), "barcode")


def get_qr_image(item, route=None, docname=None, serial_no=None):
	"""Generate a QR image for a single item row and return a public file URL.
	Exposed to print-format Jinja via the `jinja` hook."""
	if not route:
		route = get_url()
	uri = "item_qr?"
	if item.get("item_code"):
		uri += "item_code=" + urllib.parse.quote(item.get_formatted("item_code"))
	if item.get("barcode"):
		uri += "&barcode=" + urllib.parse.quote(item.get_formatted("barcode"))
	if serial_no:
		uri += "&serial_no=" + urllib.parse.quote(str(serial_no))
	if item.get("batch_no"):
		uri += "&batch_no=" + urllib.parse.quote(item.get_formatted("batch_no"))
	return qr_code_img(uri, route)


def _save_public_image(data, prefix):
	"""Write image bytes to the site's public files dir and return its URL.
	Written directly (not via save_file) so the on-disk name always matches the
	returned URL — save_file's content-hash renaming caused a 404 mismatch."""
	from frappe.utils import get_files_path

	file_name = "{0}-{1}.png".format(prefix, frappe.generate_hash(length=8))
	file_path = get_files_path()
	os.makedirs(file_path, exist_ok=True)
	with open(os.path.join(file_path, file_name), "wb") as f:
		f.write(data)
	return "/files/{0}".format(file_name)
'''

MARK = "@frappe.whitelist()\ndef make_qrcode(doc, route):"
if MARK not in src:
	print("  make_qrcode: MARKER NOT FOUND — aborting so we don't patch blind")
	sys.exit(1)
if "def get_barcode_image(" in src:
	print("  make_qrcode/tail: ALREADY PATCHED")
else:
	idx = src.index(MARK)
	src = src[:idx] + NEW_TAIL
	print("  make_qrcode/qr_code_img/get_barcode_image/get_qr_image/_save_public_image: PATCHED")

io.open(path, "w", encoding="utf-8").write(src)
PYEOF

echo
echo "== syntax check =="
/home/frappe/frappe-bench/env/bin/python -m py_compile "$F" && echo "  py_compile OK"

echo
echo "== after: relevant defs =="
grep -n "def get_item_details\|def make_qrcode\|def qr_code_img\|def get_barcode_image\|def get_qr_image\|_save_public_image\|Please save the document before" "$F" || true
