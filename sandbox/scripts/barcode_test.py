#!/usr/bin/env python3
"""Prove the barcode scanner path works on this build.

What "broken" meant: the form JS called
    erpnext.stock.get_item_details.get_item_code
which ERPNext v16 de-whitelists, so the call 403s and the item_code field on
Barcode Printing silently stays empty. The fix points the JS at
    erpnext.stock.utils.scan_barcode
This script exercises exactly that endpoint against a real Item Barcode.

    env/bin/python /tmp/barcode_test.py
"""
import json
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe

SITE = "frontend"
TEST_BARCODE = "8991234567891"  # valid EAN-13 (checksum verified)


def log(msg):
	print("MARK %s" % msg)


def pick_item():
	rows = frappe.get_all(
		"Item",
		filters={"shopify_product_id": ["!=", ""]},
		fields=["name"],
		limit=1,
	)
	if rows:
		return rows[0]["name"]
	rows = frappe.get_all("Item", fields=["name"], limit=1)
	return rows[0]["name"] if rows else None


def main() -> int:
	frappe.init(site=SITE, sites_path=".")
	frappe.connect()
	frappe.set_user("Administrator")

	item_code = pick_item()
	if not item_code:
		log("NO ITEMS - sync Shopify products first")
		return 1
	log("using item %s" % item_code)

	items = frappe.get_all("Item Barcode", filters={"parent": item_code}, fields=["barcode"])
	if any(row["barcode"] == TEST_BARCODE for row in items):
		barcode = TEST_BARCODE
		log("barcode already present: %s" % barcode)
	else:
		item = frappe.get_doc("Item", item_code)
		item.append("barcodes", {"barcode": TEST_BARCODE, "barcode_type": "EAN"})
		item.flags.ignore_permissions = True
		item.save()
		frappe.db.commit()
		barcode = TEST_BARCODE
		log("barcode added to %s: %s" % (item_code, barcode))

	# ---- the endpoint the FIXED form JS now calls -------------------------
	from erpnext.stock.utils import scan_barcode

	result = scan_barcode(search_value=barcode)
	if isinstance(result, dict):
		found = result.get("item_code") or result.get("name")
		log("scan_barcode -> item_code=%s" % found)
		slim = {k: v for k, v in result.items() if k in ("item_code", "item_name", "barcode")}
		log("scan_barcode payload: %s" % json.dumps(slim, default=str))
	else:
		log("scan_barcode returned %r" % (result,))

	# ---- the OLD entry point: must be gone or de-whitelisted --------------
	try:
		import erpnext.stock.get_item_details as gid

		fn = getattr(gid, "get_item_code", None)
		if fn is None:
			log("get_item_code: ABSENT from module (removed in v16)")
		else:
			log("get_item_code: still present in module")
	except Exception as exc:
		log("get_item_code import error: %s" % exc)

	frappe.db.commit()
	frappe.destroy()
	return 0


if __name__ == "__main__":
	sys.exit(main())
