#!/usr/bin/env python3
"""Create the production planner's ERPNext integration user and mint its API key.

The planner is a separate Node service, so it cannot use a browser session: it
authenticates with an API key/secret pair. Rather than hand it the Administrator
token (which would give the planner full control of the site), this creates a
dedicated `planner@ai-fix.local` user holding only Manufacturing roles.

`generate_keys()` is used deliberately instead of writing `api_secret` straight
into the table: the field is a Password column, so a raw write stores plaintext
and every request then dies with "Failed to decrypt key" (see docs/AI-FIX.md).

Emits two machine-readable lines for the caller to parse:

    PLANNER_API_KEY=<key>
    PLANNER_API_SECRET=<secret>

    env/bin/python /tmp/ai-fix-scheduler-token.py [--rotate]
"""
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402

SITE = os.environ.get("SITE_NAME", "frontend")
EMAIL = os.environ.get("PLANNER_USER", "planner@ai-fix.local")
ROLES = [
	"Manufacturing Manager",
	"Manufacturing User",
	# The planner's Sales Forecast tab reads Sales Orders and the batch-group
	# view sizes BOMs from Items; without these the endpoints answer 403.
	"Sales User",
	"Stock User",
]
ROTATE = "--rotate" in sys.argv


def log(msg):
	print("MARK %s" % msg)


def main():
	frappe.init(site=SITE, sites_path=".")
	frappe.connect()
	frappe.set_user("Administrator")

	if not frappe.db.exists("User", EMAIL):
		user = frappe.get_doc(
			{
				"doctype": "User",
				"email": EMAIL,
				"first_name": "Production Planner",
				"user_type": "System User",
				"send_welcome_email": 0,
				"enabled": 1,
			}
		)
		user.insert(ignore_permissions=True)
		log("user created: %s" % EMAIL)
	else:
		user = frappe.get_doc("User", EMAIL)
		if not user.enabled:
			user.enabled = 1
			user.save(ignore_permissions=True)
		log("user exists: %s" % EMAIL)

	existing_roles = {r.role for r in user.roles}
	for role in ROLES:
		if role not in existing_roles and frappe.db.exists("Role", role):
			user.append("roles", {"role": role})
			log("role granted: %s" % role)
	user.save(ignore_permissions=True)

	frappe.db.commit()

	if user.api_key and not ROTATE:
		# Keep the existing secret: rotating on every bring-up would invalidate a
		# running container for no reason. Re-run with --rotate to force it.
		secret = user.get_password("api_secret")
		if secret:
			log("reusing existing API key (%s)" % user.api_key)
			print("PLANNER_API_KEY=%s" % user.api_key)
			print("PLANNER_API_SECRET=%s" % secret)
			return

	from frappe.core.doctype.user.user import generate_keys

	keys = generate_keys(EMAIL)
	frappe.db.commit()
	log("API key minted for %s" % EMAIL)
	print("PLANNER_API_KEY=%s" % keys["api_key"])
	print("PLANNER_API_SECRET=%s" % keys["api_secret"])


if __name__ == "__main__":
	main()
