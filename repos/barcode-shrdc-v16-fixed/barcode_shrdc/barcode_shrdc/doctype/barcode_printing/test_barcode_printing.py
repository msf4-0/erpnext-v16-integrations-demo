# -*- coding: utf-8 -*-
# Copyright (c) 2021, lxy and Contributors
# See license.txt
from __future__ import unicode_literals

import unittest

from barcode_shrdc.barcode_render import drawing_to_png


class TestBarcodePrinting(unittest.TestCase):
	"""Regression tests for the server-side barcode renderer.

	These guard the fix for the ``RenderPMError: cannot import desired renderPM
	backend rlPyCairo`` failure: rendering must never depend on reportlab's
	optional native backend again.
	"""

	def _drawing(self, symbol, value):
		from reportlab.graphics.barcode import createBarcodeDrawing

		return createBarcodeDrawing(
			symbol, value=value, barHeight=40, barWidth=2, humanReadable=True
		)

	def test_renders_supported_symbologies(self):
		cases = [
			("Code128", "STR-001-0001"),
			("Standard39", "ABC-123"),
			("I2of5", "12345678"),
			("EAN13", "1234567890128"),
			("EAN8", "12345670"),
			("UPCA", "123456789012"),
		]
		for symbol, value in cases:
			with self.subTest(symbol=symbol):
				png = drawing_to_png(self._drawing(symbol, value), display_value=True)
				self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"), "not a PNG")
				self.assertGreater(len(png), 500)

	def test_human_readable_does_not_shrink_the_bars(self):
		plain = drawing_to_png(self._drawing("Code128", "STR-001-0001"), False)
		labelled = drawing_to_png(self._drawing("Code128", "STR-001-0001"), True)
		self.assertGreater(len(labelled), len(plain))
