# -*- coding: utf-8 -*-
"""Serve the embedded Metabase dashboard at /metabase.

Resolution order for the embed URL:
  1. site_config / common_site_config key ``metabase_dashboard_url`` (what the
     seed and the launcher scripts have always written);
  2. the enabled ``Metabase Dashboard`` records added by this app, newest first.

Before this fallback existed the page showed the "not configured yet" warning
whenever only the doctype was set, which made the doctype look broken.
"""

import frappe


def get_context(context):
    context.no_cache = 1
    context.title = "Manufacturing Analytics"

    dashboards = []
    try:
        dashboards = frappe.get_all(
            "Metabase Dashboard",
            filters={"enabled": 1},
            fields=["title", "dashboard_id", "metabase_url", "embed_mode", "description"],
            order_by="modified desc",
        )
    except Exception:
        # The doctype is missing on an old site that has not migrated yet: the
        # page must still render its "not configured" state instead of a 500.
        dashboards = []

    url = (frappe.conf.get("metabase_dashboard_url") or "").strip()
    if not url and dashboards:
        url = dashboards[0].get("metabase_url") or ""

    context.dashboard_url = url
    context.dashboards = dashboards
    context.active_dashboard = dashboards[0] if dashboards else None
    return context
