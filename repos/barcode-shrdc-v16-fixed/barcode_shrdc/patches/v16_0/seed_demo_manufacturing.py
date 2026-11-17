# -*- coding: utf-8 -*-
"""Install the generic manufacturing demo dataset on existing sites."""

import frappe

from barcode_shrdc.demo import ensure_demo_manufacturing


def execute():
	result = ensure_demo_manufacturing()
	frappe.logger("barcode_shrdc").info("generic demo seed: %s", result)
