import re

import frappe

# <img src="{{ get_barcode_image(...) }}" style="max-width:100%;"/> in the
# shipped print formats predates the shared helper, so every format had its own
# copy of the markup and the size. Route them through barcode_img() instead.
IMG_RE = re.compile(
	r'<img\s+src="\{\{\s*get_barcode_image\((.*?)\)\s*\}\}"\s+style="max-width:100%;"\s*/?>',
	re.S,
)


def execute():
	changed = []
	for row in frappe.get_all(
		"Print Format", filters={"doc_type": "Barcode Printing"}, fields=["name"]
	):
		doc = frappe.get_doc("Print Format", row.name)
		html = doc.html or ""
		new_html, count = IMG_RE.subn(
			lambda m: "{{ barcode_img(%s) | safe }}" % m.group(1), html
		)
		if count:
			frappe.db.set_value("Print Format", doc.name, "html", new_html)
			changed.append(doc.name)

	frappe.db.commit()
	print("barcode print formats updated:", changed or "none")
