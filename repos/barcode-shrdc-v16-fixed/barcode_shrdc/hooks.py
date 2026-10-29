# -*- coding: utf-8 -*-
from __future__ import unicode_literals
from . import __version__ as app_version

app_name = "barcode_shrdc"
app_title = "Barcode Shrdc"
app_publisher = "lxy"
app_description = "Generate barcode for items"
app_icon = "octicon octicon-file-directory"
app_color = "grey"
app_email = "xlee0008@student.monash.edu"
app_license = "MIT"

# Includes in <head>
# ------------------

# include js, css files in header of desk.html
# app_include_css = "/assets/barcode_shrdc/css/barcode_shrdc.css"
app_include_js = ["/assets/barcode_shrdc/js/scanner_barcode_patch.js"]

# include js, css files in header of web template
# web_include_css = "/assets/barcode_shrdc/css/barcode_shrdc.css"
# web_include_js = "/assets/barcode_shrdc/js/barcode_shrdc.js"

# include js in page
# page_js = {"page" : "public/js/file.js"}

# include js in doctype views
# doctype_js = {"doctype" : "public/js/doctype.js"}
# doctype_list_js = {"doctype" : "public/js/doctype_list.js"}
# doctype_tree_js = {"doctype" : "public/js/doctype_tree.js"}
# doctype_calendar_js = {"doctype" : "public/js/doctype_calendar.js"}

# Home Pages
# ----------

# application home page (will override Website Settings)
# home_page = "login"

# website user home page (by Role)
# role_home_page = {
#	"Role": "home_page"
# }

# Website user home page (by function)
# get_website_user_home_page = "barcode_shrdc.utils.get_home_page"

# Generators
# ----------

# automatically create page for each record of this doctype
# website_generators = ["Web Page"]

# Installation
# ------------

# before_install = "barcode_shrdc.install.before_install"
# after_install = "barcode_shrdc.install.after_install"

# Desk Notifications
# ------------------
# See frappe.core.notifications.get_notification_config

# notification_config = "barcode_shrdc.notifications.get_notification_config"

# Permissions
# -----------
# Permissions evaluated in scripted ways

# permission_query_conditions = {
# 	"Event": "frappe.desk.doctype.event.event.get_permission_query_conditions",
# }
#
# has_permission = {
# 	"Event": "frappe.desk.doctype.event.event.has_permission",
# }

# Document Events
# ---------------
# Hook on document methods and events

# The scanned-quantity rule used to be client-side only (a Client Script
# before_submit), so any REST submit skipped it. These are the server-side twins;
# they only fire when the document actually sets the barcode flags.
doc_events = {
	"Delivery Note": {
		"before_submit": "barcode_shrdc.validators.validate_scanned_quantities",
	},
	"Stock Entry": {
		"before_submit": "barcode_shrdc.validators.validate_stock_entry_scans",
	},
}

# Scheduled Tasks
# ---------------

# scheduler_events = {
# 	"all": [
# 		"barcode_shrdc.tasks.all"
# 	],
# 	"daily": [
# 		"barcode_shrdc.tasks.daily"
# 	],
# 	"hourly": [
# 		"barcode_shrdc.tasks.hourly"
# 	],
# 	"weekly": [
# 		"barcode_shrdc.tasks.weekly"
# 	]
# 	"monthly": [
# 		"barcode_shrdc.tasks.monthly"
# 	]
# }

# Testing
# -------

# before_tests = "barcode_shrdc.install.before_tests"

# Overriding Methods
# ------------------------------
#
# override_whitelisted_methods = {
# 	"frappe.desk.doctype.event.event.get_events": "barcode_shrdc.event.get_events"
# }
#
# each overriding function accepts a `data` argument;
# generated from the base implementation of the doctype dashboard,
# along with any modifications made in other Frappe apps
# override_doctype_dashboards = {
# 	"Task": "barcode_shrdc.task.get_dashboard_data"
# }

# fixtures
fixtures = ['Print Format','Report', 'Role Profile', 'Role', 'Custom Field', 'Client Script', 'Property Setter', 'Workflow', 'Workflow State', 'Workflow Action']


# Jinja globals exposed to print-format templates (server-side rendering of
# barcodes/QRs so they appear in print/PDF, not just the on-screen preview).
jinja = {
	"methods": [
		"barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_barcode_image",
		"barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_qr_image",
	]
}

# javascript
# doctype_js = {
#     'Item':'public/js/....'
# }
# # will extend 

# # python
# override_whitelisted_methods ={
#     "":""
# }
# write in events 