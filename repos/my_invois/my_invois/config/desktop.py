# -*- coding: utf-8 -*-
from __future__ import unicode_literals
from frappe import _

def get_data():
	return [
		{
			"module_name": "My Invois",
			"category": "Modules",
			"color": "grey",
			"icon": "octicon octicon-file",
			"type": "module",
			"label": _("MyInvois E-Invoicing")
		}
	]
