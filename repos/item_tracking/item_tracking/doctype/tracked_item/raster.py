# -*- coding: utf-8 -*-
"""Local raster fallback used only when barcode_shrdc is not importable."""
from __future__ import unicode_literals

import hashlib
import io
import os

import frappe
from frappe.utils import get_files_path


def _save_public(data, prefix):
    name = "{0}-{1}.png".format(prefix, hashlib.md5(data).hexdigest()[:12])
    path = get_files_path()
    os.makedirs(path, exist_ok=True)
    full = os.path.join(path, name)
    if not os.path.exists(full):
        with open(full, "wb") as f:
            f.write(data)
    return "/files/{0}".format(name)


def render_barcode(value, barcode_type="CODE128"):
    from reportlab.graphics.barcode import createBarcodeDrawing
    drawing = createBarcodeDrawing("Code128", value=value, barHeight=40, barWidth=2, humanReadable=1)
    return _save_public(drawing.asString("png"), "barcode")


def render_qr(url):
    import qrcode
    qr = qrcode.QRCode(border=4, error_correction=qrcode.constants.ERROR_CORRECT_H)
    qr.add_data(url)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return _save_public(buf.getvalue(), "qr")
