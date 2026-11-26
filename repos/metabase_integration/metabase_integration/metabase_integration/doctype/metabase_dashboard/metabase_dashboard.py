# -*- coding: utf-8 -*-
from __future__ import unicode_literals

import frappe
from frappe import _
from frappe.model.document import Document


class MetabaseDashboard(Document):
    def validate(self):
        self.metabase_url = (self.metabase_url or "").strip()
        if self.metabase_url and not self.metabase_url.startswith(("http://", "https://")):
            frappe.throw(
                _("Embed URL must start with http:// or https:// (got {0})").format(
                    self.metabase_url
                )
            )
        if self.dashboard_id:
            self.dashboard_id = str(self.dashboard_id).strip().strip("/")
