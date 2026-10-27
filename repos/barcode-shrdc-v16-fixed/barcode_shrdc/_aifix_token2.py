import frappe
from frappe.core.doctype.user.user import generate_keys


def run(user="Administrator"):
	"""Wipe any hand-written api_key/api_secret, then mint a proper pair.

	An earlier attempt used frappe.db.set_value() to write api_secret, which
	stores PLAINTEXT in a Password column. Reading it back then raises
	"Failed to decrypt key" before any comparison happens, so the user is left
	with a permanently broken token until the column is cleared.
	"""
	frappe.db.sql(
		"update `tabUser` set api_key = null, api_secret = null where name = %s", (user,)
	)
	frappe.db.commit()
	frappe.clear_cache()
	out = generate_keys(user)
	frappe.db.commit()
	print("MARK_TOKEN %s:%s" % (out["api_key"], out["api_secret"]))
	return out