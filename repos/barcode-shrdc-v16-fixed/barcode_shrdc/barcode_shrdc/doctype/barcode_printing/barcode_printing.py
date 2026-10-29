# -*- coding: utf-8 -*-
# Copyright (c) 2021, lxy and contributors
# For license information, please see license.txt

from __future__ import unicode_literals
import frappe, json, urllib
from frappe.model.document import Document
from frappe.model.mapper import get_mapped_doc
from frappe import msgprint, _ 
from six import string_types, iteritems
import qrcode, io, os
from io import BytesIO	
import base64
from frappe.integrations.utils import make_get_request, make_post_request, create_request_log
from frappe.utils import cstr, flt, cint, nowdate, add_days, comma_and, now_datetime, ceil, get_url, escape_html
from erpnext.manufacturing.doctype.work_order.work_order import get_item_details
import requests
from PIL import Image




class BarcodePrinting(Document):
	pass
# 	def get_open_purchase_receipt(self):
# 		""" Pull Purchase Receipt based on criteria selected"""
# 		open_pr = get_purchase_receipts(self)

# 		if open_pr:
# 			self.add_pr_in_table(open_pr)
# 		else:
# 			frappe.msgprint(_("Purchase Order not available"))

# 	def add_pr_in_table(self, open_pr):
# 		""" Add sales orders in the table"""
# 		self.set('purchase_receipt', [])

# 		for data in open_pr:
# 			self.append('purchase_receipts', {
# 				'purchase_receipt': data.name,
# 				'pr_date': data.posting_date,
# 				'supplier': data.supplier,
# 				'grand_total': data.total
# 			})

# 	def get_items(self):
# 		if self.get_items_from == "Purchase Receipt":
# 			self.get_pr_items()
# 		elif self.get_items_from == "Stock Entry":
# 			self.get_se_items()
	
# 	def get_pr_se_list(self, field, table):
# 		"""Returns a list of Purchase Orders or Stock Entries from the respective tables"""
# 		pr_se_list = [d.get(field) for d in self.get(table) if d.get(field)]
# 		return pr_se_list

# 	def get_pr_items(self):
# 		# Check for empty table or empty rows
# 		if not self.get("purchase_receipts") or not self.get_pr_se_list("purchase_receipt", "purchase_receipts"):
# 			frappe.throw(_("Please fill the Purchase Receipt table"), title=_("Purchase Receipt Required"))

# 		pr_list = self.get_pr_se_list("purchase_receipt", "purchase_receipts")
		
# 		item_condition = ""
# 		if self.item_code:
# 			item_condition = ' and pr_item.item_code = {0}'.format(frappe.db.escape(self.item_code))
# 		items = frappe.db.sql("""select distinct pr_item.parent, pr_item.item_code, pr_item.warehouse,
# 			pr_item.qty, pr_item.description, pr_item.name, pr_item.uom, pr.supplier, pr_item.barcode, 
# 			pr_item.serial_no, pr_item.batch_no, 
# 			item.barcode
# 			from `tabPurchase Receipt Item` pr_item , `tabPurchase Receipt` pr, `tabItem Barcode` item
# 			where pr_item.parent in (%s) and pr_item.docstatus = 1  and item.parent = %s""" % \
# 			(", ".join(["%s"] * len(pr_list))),self.item_code, tuple(pr_list), as_dict=1)

# 		if self.item_code:
# 			item_condition = ' and so_item.item_code = {0}'.format(frappe.db.escape(self.item_code))

# 		self.add_items(items)
	
# 	def add_items(self, items):
# 		self.set('items', [])
# 		for data in items:
# 			pi = self.append('items', {
# 				'warehouse': data.warehouse,
# 				'item_code': data.item_code,
				
# 				'description': data.description,
# 				'qty': data.qty,
# 				'supplier': data.supplier,
# 				'uom': data.uom,
# 				'barcode': data.barcode,
# 				'serial_no': data.serial_no,
# 				'batch_no': data.batch_no
# 			})

# 			if self.get_items_from == "Purchase Receipt":
# 				pi.ref_pr = data.parent
# 				pi.description = data.description

# 			elif self.get_items_from == "Stock Entry":
# 				pi.ref_se = data.parent
# 				pi.description = data.description
	
# 	def get_item_barcode(self):
# 		print(self.items)
# 		item = frappe.db.sql("""select barcode, barcode_type
# 			from `tabItem Barcode` 
# 			where parent=%s""",
# 			"ITM-001", as_dict = 1)

# 		if not item:
# 			frappe.throw(_("Item {0} is not active or end of life has been reached"))

# 		item = item[0]
		
# 		return item

	@frappe.whitelist()
	def get_item_details(self, args=None, for_update=False):
		item = frappe.db.sql("""select i.name, i.stock_uom, i.description, i.image, i.item_name, i.item_group,
				i.has_batch_no, i.sample_quantity, i.has_serial_no, i.allow_alternative_item,
				id.expense_account, id.buying_cost_center
			from `tabItem` i LEFT JOIN `tabItem Default` id ON i.name=id.parent and id.company=%s
			where i.name=%s
				and i.disabled=0
				and (i.end_of_life is null or i.end_of_life='0000-00-00' or i.end_of_life > %s)""",
			(self.company, args.get('item_code'), nowdate()), as_dict = 1)

		if not item:
			frappe.throw(_("Item {0} is not active or end of life has been reached").format(args.get("item_code")))

		item = item[0]

		ret = frappe._dict({
			'uom'			      	: item.stock_uom,
			'stock_uom'				: item.stock_uom,
			'description'		  	: item.description,
			'image'					: item.image,
			'item_name' 		  	: item.item_name,
			'qty'					: args.get("qty"),
			'conversion_factor'		: 1,
			'batch_no'				: '',
			'actual_qty'			: 0,
			'basic_rate'			: 0,
			'serial_no'				: '',
			'has_serial_no'			: item.has_serial_no,
			'has_batch_no'			: item.has_batch_no,
			'sample_quantity'		: item.sample_quantity
		})

		return ret
	

	

# def get_purchase_receipts(self):
# 	pr_filter = item_filter = ""
# 	if self.from_date:
# 		pr_filter += " and pr.posting_date >= %(from_date)s"
# 	if self.to_date:
# 		pr_filter += " and pr.posting_date <= %(to_date)s"
# 	if self.warehouse:
# 		pr_filter += " and pr.set_warehouse = %(warehouse)s"
# 	if self.supplier:
# 		pr_filter += " and pr.supplier = %(supplier)s"

# 	if self.item_code:
# 		item_filter += " and pr_item.item_code = %(item)s"

# 	open_pr = frappe.db.sql("""
# 		select distinct pr.name, pr.posting_date, pr.supplier, pr.base_grand_total
# 		from `tabPurchase Receipt` pr, `tabPurchase Receipt Item` pr_item
# 		where pr_item.parent = pr.name
# 			and pr.docstatus = 1 and pr.status not in ("Stopped", "Closed")
# 			and pr.company = %(company)s
# 		""".format(pr_filter, item_filter), {
# 			"from_date": self.from_date,
# 			"to_date": self.to_date,
# 			"supplier": self.supplier,
# 			"set_warehouse": self.warehouse,
# 			"item": self.item_code,
# 			"company": self.company
# 		}, as_dict=1)
# 	return open_pr




@frappe.whitelist()
def pr_make_barcode(source_name, target_doc=None):
	doc = get_mapped_doc("Purchase Receipt", source_name, {
		"Purchase Receipt": {
			"doctype": "Barcode Printing",
			"validation": {
				"docstatus": ["=", 1]
			}
		},
		"Purchase Receipt Item": {
			"doctype": "Barcode Generator Items",
			"field_map": {
				"stock_qty": "qty",
				"batch_no": "batch_no",
				"parent": "ref_pr",
				"price_list_rate":"basic_rate",
				"serial_no":"serial_no",
				"batch_no":"batch_no",
				"set_warehouse":"warehouse"
			},
		}
	}, target_doc)

	return doc

@frappe.whitelist()
def se_make_barcode(source_name, target_doc=None):

	def check_manufacturing(d):
		if frappe.get_doc("Stock Entry",d.parent).stock_entry_type == "Manufacture":
			return  (d.t_warehouse != None)
		return 1

	doclist = get_mapped_doc("Stock Entry", source_name, {
		"Stock Entry": {
			"doctype": "Barcode Printing",
			"validation": {
				"docstatus": ["=", 1],
			},
			"field_map": {
				"get_items_from" :"doctype"
			}
		},
		"Stock Entry Detail": {
			"doctype": "Barcode Generator Items",
			"field_map": {
				"valuation_rate":"rate",
				"qty": "qty",
				"uom": "uom",
				"parent": "ref_se",
				"serial_no":"serial_no",
				"batch_no":"batch_no",
				"additional_cost":"additional_cost"	,
				"t_warehouse":"warehouse"
			},
			"condition":check_manufacturing
		}
	}, target_doc)

	return doclist

@frappe.whitelist()
def search_item_serial_or_batch_or_barcode_number(search_value,item):
	# search barcode no
	item = json.loads(item)
	barcode_data = frappe.db.get_value('Item Barcode', {'parent': item["item_code"]}, ['barcode', 'barcode_type', 'parent as item_code'], as_dict=True)
	if barcode_data:
		if barcode_data.barcode_type == "EAN":
			barcode_data.barcode_type = "EAN13"
		elif barcode_data.barcode_type == "UPC-A":
			barcode_data.barcode_type = "UPC"
		return barcode_data

	# search serial no
	serial_no_data = frappe.db.get_value('Serial No', search_value, ['name as serial_no', 'item_code'], as_dict=True)
	if serial_no_data:
		return serial_no_data

	# search batch no
	batch_no_data = frappe.db.get_value('Batch', search_value, ['name as batch_no', 'item as item_code'], as_dict=True)
	if batch_no_data:
		return batch_no_data

	return {}

@frappe.whitelist()
def scan_barcode(search_value):
	"""Resolve one scanned value to an ERPNext row payload.

	Replaces `erpnext.selling.page.point_of_sale.point_of_sale.
	search_serial_or_batch_or_barcode_number`, which no longer exists in
	ERPNext v16 -- the Delivery Note / Stock Entry scan fields were calling a
	method that had been removed, so scanning silently failed with
	"Method not found".

	Returns {} when nothing matches, otherwise
	{item_code, barcode, batch_no, serial_no} - exactly the keys the client
	scripts read after `frappe.call`.
	"""
	value = (search_value or "").strip()
	if not value:
		return {}

	# 1. Item Barcode row (the normal scan path)
	barcode_row = frappe.db.get_value(
		"Item Barcode", {"barcode": value}, ["parent", "barcode"], as_dict=True
	)
	if barcode_row and barcode_row.parent:
		return {
			"item_code": barcode_row.parent,
			"barcode": barcode_row.barcode,
			"batch_no": None,
			"serial_no": None,
		}

	# 2. Serial No
	if frappe.db.exists("Serial No", value):
		serial = frappe.db.get_value("Serial No", value, ["item_code", "batch_no"], as_dict=True)
		if serial and serial.item_code:
			return {
				"item_code": serial.item_code,
				"barcode": value,
				"batch_no": serial.batch_no,
				"serial_no": value,
			}

	# 3. Batch No
	if frappe.db.exists("Batch", value):
		batch = frappe.db.get_value("Batch", value, ["item", "batch_id"], as_dict=True)
		if batch and batch.item:
			return {
				"item_code": batch.item,
				"barcode": value,
				"batch_no": value,
				"serial_no": None,
			}

	# 4. Typed/pasted item code
	if frappe.db.exists("Item", value):
		return {"item_code": value, "barcode": value, "batch_no": None, "serial_no": None}

	return {}

@frappe.whitelist()
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

@frappe.whitelist()
def create_barcode_printing(throw_if_missing, se_id,pr_id):	
	bp = frappe.new_doc('Barcode Printing')

	if(se_id):
		se = frappe.get_doc("Stock Entry", se_id)
		for item in se.items:
			if 	item.t_warehouse != None:
				row = bp.append('items', {})
				row.item_code = item.item_code
				row.qty = item.qty
				row.basic_rate = item.basic_rate
				row.rate = item.valuation_rate
				row.uom = item.uom
				row.additional_cost = item.additional_cost
				row.conversion_factor = item.conversion_factor
				row.serial_no = item.serial_no
				row.batch_no = item.batch_no
				row.ref_se = se_id
	
	if(pr_id):
		pr = frappe.get_doc("Purchase Receipt",pr_id)
		for item in pr.items:
			row = bp.append('items', {})
			row.item_code = item.item_code
			row.qty = item.qty
			row.basic_rate = item.price_list_rate
			row.rate = item.rate
			row.uom = item.uom
			row.serial_no = item.serial_no
			row.batch_no = item.batch_no
			row.ref_pr = pr_id
			row.warehouse = pr.set_warehouse

	bp.insert(
		ignore_mandatory=True
		)

	if not frappe.db.exists(bp.doctype, bp.name):
		if throw_if_missing:
			frappe.throw('Linked document (Stock Entry / Purchase Receipt) not found')
	return frappe.get_doc(bp.doctype, bp.name)

@frappe.whitelist()
def make_qrcode(doc, route):
	"""Generate QR codes for the item rows and return HTML <img> tags.

	Works on an UNSAVED document: it reads the item rows straight from the
	passed `doc` JSON (the same contract as `get_preview_html`), so clicking
	"Create QR" before saving no longer throws "Please save the document".
	"""
	docinfo = json.loads(doc) if isinstance(doc, str) else doc
	docinfo = docinfo or {}
	items = docinfo.get("items") or []
	route = route or get_url()

	qr_html = []
	for item in items:
		item_code = (item.get("item_code") or "").strip()
		barcode = (item.get("barcode") or "").strip()
		batch_no = (item.get("batch_no") or "").strip()
		serial_no = item.get("serial_no")
		qty = flt(item.get("qty") or 0)
		if not item_code and not barcode:
			continue
		serials = []
		if qty and serial_no and isinstance(serial_no, str):
			serials = [s for s in serial_no.split("\n") if s and s.strip()]
		if serials:
			for serial in serials:
				uri = _item_qr_uri(item_code, barcode, batch_no, serial)
				qr_html.append('<img src="' + qr_code_img(uri, route) + '" width="240px"/><br>')
		else:
			uri = _item_qr_uri(item_code, barcode, batch_no, None)
			qr_html.append('<img src="' + qr_code_img(uri, route) + '" width="240px"/><br>')
	return "".join(qr_html)


def _item_qr_uri(item_code, barcode, batch_no, serial_no):
	"""Build the item_qr query string the QR image encodes (shared helper)."""
	params = []
	if item_code:
		params.append("item_code=" + urllib.parse.quote(item_code))
	if barcode:
		params.append("barcode=" + urllib.parse.quote(barcode))
	if batch_no:
		params.append("batch_no=" + urllib.parse.quote(batch_no))
	if serial_no:
		params.append("serial_no=" + urllib.parse.quote(cstr(serial_no)))
	return "item_qr?" + "&".join(params)


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
	# reportlab uses its own names for a few formats. 'Code39' is NOT registered
	# (createBarcodeDrawing raises KeyError) - the registered name is
	# 'Standard39' (and 'Standard93' for CODE93), so the previous mapping made
	# every CODE39 label render as Code128 without any error.
	rl_map = {
		"EAN": "EAN13",
		"UPC": "UPCA",
		"UPC-A": "UPCA",
		"CODE39": "Standard39",
		"CODE93": "Standard93",
		"CODE128": "Code128",
		"EAN13": "EAN13",
		"EAN8": "EAN8",
	}
	rl_type = rl_map.get(barcode_type, barcode_type)

	# Validate the digit count BEFORE handing the value to reportlab. reportlab
	# happily pads/accepts short numeric values for the fixed-length symbologies,
	# which prints a label that scans as something else - worse than an error.
	fixed_length = {"EAN13": 13, "EAN8": 8, "UPCA": 12, "UPCE": 8}
	if rl_type in fixed_length:
		value_str = cstr(barcode)
		digits = "".join(ch for ch in value_str if ch.isdigit())
		needed = fixed_length[rl_type]
		if len(digits) not in (needed, needed - 1):
			frappe.throw(
				_("Cannot print {0} barcode for value {1}: {0} needs {2} digits "
				  "(or {3} without the checksum). Use a {2}-digit value or choose CODE128.").format(
					barcode_type, value_str, needed, needed - 1
				),
				title=_("Barcode not printable"),
			)
		if digits != value_str:
			barcode = digits

	bar_kwargs = {
		"value": cstr(barcode),
		"barHeight": flt(height) or 40,
		"barWidth": flt(width) or 2,
		"humanReadable": cint(display_value) == 1,
	}
	try:
		drawing = createBarcodeDrawing(rl_type, **bar_kwargs)
	except Exception as exc:
		# Do not silently print a different symbology: a code that scans as
		# Code128 when CODE39/EAN13 was asked for is worse than an error.
		if rl_type == "Code128":
			raise
		frappe.log_error(
			title="Barcode render failed for %s" % barcode_type,
			message="value=%r symbology=%r error=%s" % (barcode, barcode_type, exc),
		)
		frappe.throw(
			_("Cannot print {0} barcode for value {1}: {2}. Use a value valid for that "
			  "symbology (e.g. 13 digits for EAN13) or choose CODE128.").format(
				barcode_type, cstr(barcode), cstr(exc)
			),
			title=_("Barcode not printable"),
		)

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

	import hashlib
	# Name by CONTENT hash so repeated preview/print calls reuse the same file
	# instead of accumulating a new PNG per render.
	file_name = "{0}-{1}.png".format(prefix, hashlib.md5(data).hexdigest()[:12])
	file_path = get_files_path()
	os.makedirs(file_path, exist_ok=True)
	full = os.path.join(file_path, file_name)
	if not os.path.exists(full):
		with open(full, "wb") as f:
			f.write(data)
	return "/files/{0}".format(file_name)


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
		return '<div class="label-item-barcode label-field"><div class="barcode-container">' \
			'<img src="' + cstr(url) + '" style="max-width:100%;"/></div></div>'

	def code_line(item):
		return '<div class="label-item-code label-field">' + \
			escape_html(cstr(item.get("item_code"))) + ": " + \
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
			serial_list = serials.split("\n")
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
