# -*- coding: utf-8 -*-
"""Local raster fallback used only when barcode_shrdc is not importable.

ReportLab 5 removed the old ``_renderPM`` C extension: ``Drawing.asString("png")``
now goes through ``rlPyCairo``/``pycairo``, which is not installed here (and has
no wheel for Python 3.14). We therefore try PNG first and fall back to SVG,
which ReportLab renders in pure Python. Browsers, the Desk and wkhtmltopdf all
display SVG in ``<img>`` tags, so the barcode/QR still render everywhere.
"""
from __future__ import unicode_literals

import hashlib
import io
import os

import frappe
from frappe.utils import get_files_path

# reportlab's createBarcodeDrawing names -> keep the tracking default stable.
_BARCODE_TYPES = {
    "CODE128": "Code128",
    "CODE39": "Standard39",
    "EAN13": "EAN13",
    "EAN8": "EAN8",
    "UPCA": "UPCA",
    "ITF": "I2of5",
}


def _save_public(data, prefix, ext="png"):
    if isinstance(data, str):
        data = data.encode("utf-8")
    name = "{0}-{1}.{2}".format(prefix, hashlib.md5(data).hexdigest()[:12], ext)
    path = get_files_path()
    os.makedirs(path, exist_ok=True)
    full = os.path.join(path, name)
    if not os.path.exists(full):
        with open(full, "wb") as f:
            f.write(data)
    return "/files/{0}".format(name)


def render_barcode(value, barcode_type="CODE128"):
    from reportlab.graphics.barcode import createBarcodeDrawing

    rl_type = _BARCODE_TYPES.get((barcode_type or "CODE128").upper(), "Code128")
    drawing = createBarcodeDrawing(
        rl_type, value=str(value), barHeight=40, barWidth=2, humanReadable=1
    )
    try:
        return _save_public(drawing.asString("png"), "barcode", "png")
    except Exception:
        # No renderPM backend (rlPyCairo/pycairo) -> pure-Python SVG output.
        return _save_public(drawing.asString("svg"), "barcode", "svg")


def render_qr(url):
    try:
        import qrcode

        qr = qrcode.QRCode(border=4, error_correction=qrcode.constants.ERROR_CORRECT_H)
        qr.add_data(url)
        qr.make(fit=True)
        img = qr.make_image(fill_color="black", back_color="white")
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return _save_public(buf.getvalue(), "qr", "png")
    except Exception:
        # Last-resort pure-Python SVG QR (no Pillow / qrcode[svg] needed).
        import pyqrcode

        code = pyqrcode.create(str(url), error="H")
        return _save_public(code.svg_as_string(scale=6, border=4), "qr", "svg")
