# -*- coding: utf-8 -*-
from __future__ import unicode_literals

import frappe


def get_context(context):
    """Context for the /metabase-dashboard website page that embeds the Metabase
    'ERPNext Monitoring' dashboard inline."""
    context.no_cache = 1
    context.show_sidebar = 0
    context.title = "ERPNext Monitoring"
    # Public (read-only) share link for the Metabase dashboard. Stable for this
    # instance; regenerate in Metabase → dashboard → Sharing if it changes.
    context.metabase_url = "http://localhost:3005/public/dashboard/fbdade7b-258e-41db-b492-192840eb8926"
    return context
