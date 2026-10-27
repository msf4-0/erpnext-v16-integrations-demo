#!/usr/bin/env bash
# barcode_shrdc on v16 — the on-form "Preview:" sections.
#
# Symptom: ticking "Print Barcode" / "Print Serial No. Barcode" / "Print Batch
# No. Barcode" left the Preview sections empty (or only sometimes worked). The
# sections were rendered entirely client-side: `$.getScript("https://cdn.jsdelivr.
# net/.../JsBarcode.all.min.js", ...)` then `JsBarcode(".barcode"+i, ...)`. That
# needs the BROWSER to reach the CDN at click time; if it can't (offline/blocked/
# slow, or the script errors) nothing renders. It also ignored the app's own
# Barcode Configuration (width/height/display_value) that the print formats use.
#
# Fix: render the preview HTML server-side with the SAME renderers the print
# formats use (get_barcode_image), via a new whitelisted get_preview_html().
# No CDN, no client-side JsBarcode, and the preview now matches the print output.
# Previews work on an UNSAVED doc too (they only need the item rows).
#
# Also makes _save_public_image() name files by CONTENT hash instead of a random
# hash, so repeated preview toggles reuse one file per (kind,barcode,format)
# instead of accumulating a new PNG on every click.
#
# Idempotent.
set -uo pipefail
APP=/home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc
PY="$APP/barcode_shrdc/doctype/barcode_printing/barcode_printing.py"
JS="$APP/barcode_shrdc/doctype/barcode_printing/barcode_printing.js"
cd /home/frappe/frappe-bench || exit 1

echo "== before =="
grep -n "def get_preview_html\|def _save_public_image" "$PY" | sed 's/^/  /' || true
grep -nc "cdn.jsdelivr.net" "$JS" | sed 's/^/  jsdelivr occurrences: /'

echo
echo "== 1) python: escape_html import + get_preview_html + content-hash files =="
python3 - "$PY" <<'PYEOF'
import io, re, sys

path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()

# --- import escape_html (idempotent) ---
if "escape_html" in src:
    print("  escape_html: already imported")
else:
    old_imp = "from frappe.utils import cstr, flt, cint, nowdate, add_days, comma_and, now_datetime, ceil, get_url"
    new_imp = "from frappe.utils import cstr, flt, cint, nowdate, add_days, comma_and, now_datetime, ceil, get_url, escape_html"
    if old_imp in src:
        src = src.replace(old_imp, new_imp, 1)
        print("  escape_html: import ADDED")
    else:
        print("  escape_html: import MARKER NOT FOUND — aborting")
        sys.exit(1)

# --- _save_public_image: content-hash naming (dedup) ---
old_save = '''	file_name = "{0}-{1}.png".format(prefix, frappe.generate_hash(length=8))
	file_path = get_files_path()
	os.makedirs(file_path, exist_ok=True)
	with open(os.path.join(file_path, file_name), "wb") as f:
		f.write(data)
	return "/files/{0}".format(file_name)'''
new_save = '''	import hashlib
	# Name by CONTENT hash so repeated preview/print calls reuse the same file
	# instead of accumulating a new PNG per render.
	file_name = "{0}-{1}.png".format(prefix, hashlib.md5(data).hexdigest()[:12])
	file_path = get_files_path()
	os.makedirs(file_path, exist_ok=True)
	full = os.path.join(file_path, file_name)
	if not os.path.exists(full):
		with open(full, "wb") as f:
			f.write(data)
	return "/files/{0}".format(file_name)'''
if "hashlib.md5(data)" in src:
    print("  _save_public_image: already content-hashed")
elif old_save in src:
    src = src.replace(old_save, new_save, 1)
    print("  _save_public_image: -> content hash")
else:
    print("  _save_public_image: MARKER NOT FOUND")

# --- get_preview_html (append if absent) ---
if "def get_preview_html(" in src:
    print("  get_preview_html: already present")
else:
    block = '''

@frappe.whitelist()
def get_preview_html(doc, kind="sku"):
	"""Render the on-form "Preview:" sections server-side so they do not depend
	on the client loading JsBarcode from a CDN. Returns HTML with real
	/files/*.png <img> URLs (same renderer the print formats use). Works on an
	unsaved document because it only reads the item rows."""
	docinfo = json.loads(doc) if isinstance(doc, str) else doc
	docinfo = docinfo or {}
	items = docinfo.get("items") or []
	config = frappe.get_doc("Barcode Configuration")

	def one_barcode(value, barcode_type):
		url = get_barcode_image(
			value, barcode_type, config.width, config.height, config.display_value
		)
		return '<div class="label-item-barcode label-field"><div class="barcode-container">' \\
			'<img src="' + cstr(url) + '" style="max-width:100%;"/></div></div>'

	def code_line(item):
		return '<div class="label-item-code label-field">' + \\
			escape_html(cstr(item.get("item_code"))) + ": " + \\
			escape_html(cstr(item.get("item_name"))) + "</div>"

	html = ['<div class="dashboard-section">']

	if kind == "sku":
		for item in items:
			barcode = item.get("barcode")
			barcode_type = item.get("barcode_type")
			if not (barcode and barcode_type):
				continue
			html.append('<div class="row"><div class="barcode-label-container">'
			            '<div class="barcode-label" id="barcode-label">')
			html.append(one_barcode(barcode, barcode_type))
			html.append(code_line(item))
			html.append('<div class="label-item-price label-field2">RM '
			            + "%.2f" % flt(item.get("rate")) + "</div>")
			html.append('<div style="font-weight:bold;font-family:Sans-serif;">x'
			            + escape_html(cstr(item.get("qty"))) + "</div><hr>")
			html.append("</div></div></div>")

	elif kind == "serial":
		barcode_type = docinfo.get("serial_barcode_type") or "CODE128"
		for item in items:
			serials = item.get("serial_no")
			if not (serials and isinstance(serials, str)):
				continue
			serial_list = serials.split("\\n")
			if serial_list and serial_list[-1] == "":
				serial_list.pop()
			html.append('<div class="row"><div class="barcode-label-container">'
			            '<div class="barcode-label" id="barcode-label">')
			for serial in serial_list:
				if not serial:
					continue
				html.append(one_barcode(serial, barcode_type))
				html.append(code_line(item))
				html.append("<hr>")
			html.append("</div></div></div>")

	elif kind == "batch":
		barcode_type = docinfo.get("batch_barcode_type") or "CODE128"
		for item in items:
			batch = item.get("batch_no")
			if not batch:
				continue
			html.append('<div class="row"><div class="barcode-label-container">'
			            '<div class="barcode-label" id="barcode-label">')
			html.append(one_barcode(batch, barcode_type))
			html.append(code_line(item))
			html.append('<div style="font-weight:bold;font-family:Sans-serif;">x'
			            + escape_html(cstr(item.get("qty"))) + "</div><hr>")
			html.append("</div></div></div>")

	else:
		frappe.throw(_("Unknown preview kind: {0}").format(kind))

	html.append("</div>")
	return "".join(html)
'''
    src = src.rstrip("\n") + "\n" + block
    print("  get_preview_html: ADDED")

io.open(path, "w", encoding="utf-8").write(src)
PYEOF

echo
echo "== 2) js: replace the 3 CDN-based preview renderers with a server call =="
python3 - "$JS" <<'PYEOF'
import io, sys

path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()


def replace_between(src, start_marker, next_marker, new_text):
    i = src.index(start_marker)
    j = src.index(next_marker, i)
    return src[:i] + new_text + src[j:]


def renderer(field, kind):
    return (
        "\tshow_%s_barcode: function(frm) {\n" % ("sku" if field == "barcodes" else ("serial" if field == "serials" else "batch"))
        + "\t\tif(frm.doc.show_%s)\n" % ("sku" if field == "barcodes" else ("serial_no" if field == "serials" else "batch_no"))
        + "\t\t{\n"
        + "\t\t\t// Server-side preview (no CDN / client-side JsBarcode needed).\n"
        + "\t\t\tfrappe.call({\n"
        + '\t\t\t\tmethod: "barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_preview_html",\n'
        + "\t\t\t\targs: {doc: frm.doc, kind: \"%s\"},\n" % kind
        + "\t\t\t\tcallback: function(r) {\n"
        + "\t\t\t\t\t$(frm.fields_dict['%s'].$wrapper).html(r.message || \"\")\n" % field
        + '\t\t\t\t\t\t.css({"margin-left": "20px", "margin-top": "10px", "font-family": "monospace"});\n'
        + "\t\t\t\t}\n"
        + "\t\t\t});\n"
        + "\t\t}\n"
        + "\t},\n"
    )


changes = []
specs = [
    ("\tshow_sku_barcode: function(frm) {", "\tshow_serial_no_barcode: function(frm) {", "barcodes", "sku"),
    ("\tshow_serial_no_barcode: function(frm) {", "\tshow_batch_no_barcode: function(frm) {", "serials", "serial"),
    ("\tshow_batch_no_barcode: function(frm) {", "\tset_serial_no: function(frm, cdt, cdn, callback) {", "batchs", "batch"),
]
for start, nxt, field, kind in specs:
    if "get_preview_html" in src and 'kind: "%s"' % kind in src:
        changes.append("%s: already server-side" % field)
        continue
    if start not in src or nxt not in src:
        changes.append("%s: MARKER NOT FOUND" % field)
        continue
    src = replace_between(src, start, nxt, renderer(field, kind))
    changes.append("%s: -> get_preview_html" % field)

io.open(path, "w", encoding="utf-8").write(src)
for c in changes:
    print("  " + c)
PYEOF

echo
echo "== 3) syntax checks =="
env/bin/python -m py_compile "$PY" && echo "  py_compile OK"
if command -v node >/dev/null 2>&1; then
  node --check "$JS" && echo "  node --check OK"
fi

echo
echo "== after =="
grep -n "def get_preview_html\|hashlib.md5" "$PY" | sed 's/^/  /'
echo "  jsdelivr occurrences now: $(grep -c 'cdn.jsdelivr.net' "$JS")"
grep -n "get_preview_html" "$JS" | sed 's/^/  /'
