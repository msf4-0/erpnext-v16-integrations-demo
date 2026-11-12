# -*- coding: utf-8 -*-
"""Rasterise reportlab barcode drawings to PNG without renderPM.

Why this module exists
----------------------
reportlab's ``Drawing.asString("png")`` goes through ``renderPM``, which since
reportlab 4 requires an *optional native* backend: ``rlPyCairo`` (Cairo) or the
legacy ``_renderPM`` C extension. Neither is a pure-Python dependency:

* ``rlPyCairo`` has to compile against ``libcairo2-dev`` + ``pkg-config`` and
  ships no wheel for the Python version used by this bench (3.14), so
  ``pip install`` fails inside the image; and
* reportlab 5 dropped ``_renderPM`` entirely.

The result was a hard ``RenderPMError`` on *every* barcode: the on-form
preview, the print formats and the PDF all stopped working even though the
symbology encoder itself was fine.

The encoder is the valuable, trusted part of reportlab and it is pure Python.
So we keep it, ask it for its vector shapes (bars + human-readable text), and
draw those with Pillow (already a hard Frappe dependency for QR codes and
image handling). No native library, no extra pip package, deterministic output.

Two reportlab families are supported:
  * Flowable barcodes (Code128, Code39, I2of5, ...) which expose a bar-pattern
    string of modules; and
  * widget barcodes (EAN13, EAN8, UPCA, ISBN) whose ``draw()`` already returns
    a ``Group`` of ``Rect``/``String`` shapes in points.
"""

from io import BytesIO
from string import ascii_lowercase

import frappe
from frappe.utils import cstr, flt

# Points -> pixels. A barcode is measured in PostScript points (1/72"), so 4x
# is ~288 dpi: crisp in print and on screen.
DEFAULT_SCALE = 4
MAX_PIXEL_WIDTH = 6000


def drawing_to_png(drawing, display_value=False, scale=DEFAULT_SCALE):
	"""Render a reportlab barcode ``Drawing`` to PNG bytes."""
	from PIL import Image, ImageDraw

	widget = drawing.contents[0]
	layout = _layout(widget, display_value)
	if not layout["bars"]:
		frappe.throw(
			frappe._("Barcode renderer produced no bars for {0}").format(
				cstr(getattr(widget, "value", ""))
			)
		)

	width_pt = max(layout["width"], max(x + w for x, _y, w, _h in layout["bars"]))
	height_pt = max(layout["height"], 1.0)
	margin_pt = 2.0

	if width_pt * scale > MAX_PIXEL_WIDTH:
		scale = max(1, int(MAX_PIXEL_WIDTH / width_pt))

	width_px = max(1, int(round((width_pt + margin_pt * 2) * scale)))
	height_px = max(1, int(round((height_pt + margin_pt * 2) * scale)))

	image = Image.new("RGB", (width_px, height_px), "white")
	draw = ImageDraw.Draw(image)

	def px(value):
		return (margin_pt + value) * scale

	def py(value):
		# reportlab y grows upwards from the baseline; Pillow grows downwards.
		return (margin_pt + height_pt - value) * scale

	for x, y, width, height in layout["bars"]:
		top = py(y + height)
		bottom = py(y)
		draw.rectangle(
			[px(x), top, max(px(x) + 1, px(x + width)), max(bottom, top + 1)],
			fill="black",
		)

	for x, y, text, font_pt, anchor, color in layout["texts"]:
		font = _load_font(max(1, int(round(font_pt * scale))))
		draw.text(
			(px(x), py(y)),
			text,
			font=font,
			fill=_pil_color(color),
			anchor={"middle": "ms", "end": "rs"}.get(anchor, "ls"),
		)

	buffer = BytesIO()
	image.save(buffer, format="PNG", optimize=True)
	return buffer.getvalue()


def _layout(widget, display_value):
	"""Return {'width','height','bars':[(x,y,w,h)],'texts':[(x,y,text,size,anchor,color)]}."""
	from reportlab.graphics.shapes import Group, Rect, String

	if hasattr(widget, "_calculate"):
		return _flowable_layout(widget, display_value)

	drawn = widget.draw()
	if not isinstance(drawn, Group):
		drawn = Group([drawn])

	layout = {
		"width": flt(getattr(widget, "width", 0)) or 1.0,
		"height": flt(getattr(widget, "barHeight", 0)) or 1.0,
		"bars": [],
		"texts": [],
	}
	for shape in drawn.contents:
		if isinstance(shape, Rect):
			if shape.fillColor is None:
				continue
			layout["bars"].append(
				(flt(shape.x), flt(shape.y), flt(shape.width), flt(shape.height))
			)
		elif isinstance(shape, String):
			layout["texts"].append(
				(
					flt(shape.x),
					flt(shape.y),
					cstr(shape.text),
					flt(getattr(shape, "fontSize", 9)) or 9,
					getattr(shape, "textAnchor", "start") or "start",
					getattr(shape, "fillColor", None),
				)
			)
	return layout


def _flowable_layout(widget, display_value):
	"""Layout for the bar-pattern (Flowable) barcode family."""
	widget._calculate()
	bar_width_pt = flt(widget._width) or 1.0
	bar_height_pt = flt(widget.barHeight) or 40
	font_pt = flt(getattr(widget, "fontSize", 9)) or 9

	# Reserve a strip at the bottom for the human-readable text, then draw the
	# bars above it. (reportlab's own flowables put the text on top of the bars,
	# which is unreadable on a printed label.)
	text_area_pt = font_pt * 1.5 if display_value else 0.0
	bars = [
		(x, text_area_pt, width, bar_height_pt) for x, width in _bar_rects(widget)
	]
	texts = []
	if display_value:
		text = cstr(widget._humanText())
		if text:
			texts.append(
				(bar_width_pt / 2, font_pt * 0.3, text, font_pt, "middle", None)
			)

	return {
		"width": bar_width_pt,
		"height": bar_height_pt + text_area_pt,
		"bars": bars,
		"texts": texts,
	}


def _bar_rects(widget):
	"""Yield ``(x, width)`` in points for every bar of a reportlab widget.

	reportlab has two pattern alphabets:
	  * ``MultiWidthBarcode`` (Code128, Code93, ...): each character is a run
	    of ``ord(c) - 96`` modules, uppercase = bar, lowercase = space.
	  * base ``Barcode`` (Code39, I2of5, Codabar, MSI, Code11): ``b``/``B``
	    are narrow/wide bars, ``s``/``S`` narrow/wide spaces, ``i`` the gap.
	"""
	from reportlab.graphics.barcode.common import MultiWidthBarcode

	bar_width = flt(widget.barWidth) or 1.0
	ratio = flt(getattr(widget, "ratio", 2.0)) or 2.0
	left = flt(getattr(widget, "lquiet", 0)) if getattr(widget, "quiet", False) else 0.0
	multi_width = isinstance(widget, MultiWidthBarcode)

	for char in getattr(widget, "decomposed", "") or "":
		if multi_width:
			units = ord(char.lower()) - 96
			if units <= 0:
				continue
			span = bar_width * units
			if char in ascii_lowercase:
				left += span
			else:
				yield left, span
				left += span
		elif char == "i":
			left += flt(getattr(widget, "gap", 0)) or bar_width
		elif char == "s":
			left += bar_width
		elif char == "S":
			left += bar_width * ratio
		elif char == "b":
			yield left, bar_width
			left += bar_width
		elif char == "B":
			yield left, bar_width * ratio
			left += bar_width * ratio


def _pil_color(color):
	if color is None:
		return "black"
	try:
		return color.hexval().replace("0x", "#")
	except Exception:
		return "black"


def _load_font(size):
	from PIL import ImageFont

	for path in (
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
		"/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
	):
		try:
			return ImageFont.truetype(path, size)
		except Exception:
			continue
	try:
		return ImageFont.load_default(size=size)
	except Exception:
		return ImageFont.load_default()
