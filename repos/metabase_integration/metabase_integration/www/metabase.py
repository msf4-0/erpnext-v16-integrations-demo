# -*- coding: utf-8 -*-
"""Serve the embedded Metabase dashboard at /metabase."""

import frappe


def get_context(context):
    context.no_cache = 1
    context.dashboard_url = frappe.conf.get("metabase_dashboard_url") or ""
    context.title = "Manufacturing Analytics"
    return context
