# -*- coding: utf-8 -*-
"""Single source of truth for how a barcode is displayed.

Before this module the barcode markup/size was duplicated in
``get_preview_html()`` (Python) and in three Jinja print formats, so changing
the label size meant editing four places and they drifted apart. Everything now
calls :func:`barcode_img` / :func:`label_html` and the size lives in one
constant.
"""

import frappe
from frappe.utils import cstr, escape_html, flt

# Physical width of the barcode on a label. The A4 label is 51.5 mm wide; the
# image is capped to this width and scales down inside narrower containers.
# Tune here only - preview and every print format read this constant.
BARCODE_MAX_WIDTH_MM = 60

# A Code 128 module narrower than ~0.25 mm stops scanning reliably on cheap
# laser printers, so refuse to shrink below this.
MIN_MODULE_WIDTH_MM = 0.25


def barcode_img(value, barcode_type=None, width=None, height=None,
                display_value=None, docname=None):
	"""Return the ``<img>`` tag for one barcode, sized consistently."""
	from barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing import (
		get_barcode_image,
	)

	url = get_barcode_image(
		value, barcode_type, width, height, display_value, docname
	)
	return (
		'<img class="barcode-img" src="{url}" '
		'style="display:block;width:100%;max-width:{max_width}mm;height:auto;" />'
	).format(url=escape_html(cstr(url)), max_width=BARCODE_MAX_WIDTH_MM)


def label_html(item, barcode_value, barcode_type=None, width=None, height=None,
               display_value=None, docname=None, show_price=False,
               show_qty=False, lines=None):
	"""Return the full label card for one barcode.

	Used by the on-form preview. The Jinja print formats build the same card
	with the same ``barcode_img`` helper so preview and print cannot drift.
	"""
	lines = lines or []
	code = cstr(item.get("item_code") or "")
	name = cstr(item.get("item_name") or "")

	parts = [
		'<div class="row"><div class="barcode-label-container">',
		'<div class="barcode-label" id="barcode-label">',
		barcode_img(barcode_value, barcode_type, width, height, display_value, docname),
	]
	if code:
		parts.append(
			'<div class="label-item-code label-field">'
			+ escape_html(code) + ": " + escape_html(name) + "</div>"
		)
	for line in lines:
		parts.append('<div class="label-item-code label-field">' + escape_html(cstr(line)) + "</div>")
	if show_price:
		parts.append(
			'<div class="label-item-price label-field2">RM '
			+ "%.2f" % flt(item.get("rate")) + "</div>"
		)
	if show_qty:
		parts.append(
			'<div style="font-weight:bold;font-family:Sans-serif;">x'
			+ escape_html(cstr(item.get("qty"))) + "</div>"
		)
	parts.append("<hr></div></div></div>")
	return "".join(parts)
