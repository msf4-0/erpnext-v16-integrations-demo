#!/usr/bin/env python3
"""Bootstrap the minimum ERPNext master data the Shopify bridge needs.

A site created with `bench new-site --install-app erpnext` has NO company, no
chart of accounts, no UOM, no item group and no warehouse - so every sync
fails on a MandatoryError. This creates the small set that Sales Orders and
Items actually require:

    UOM "Nos"  ->  Item Group "Products"  ->  Company (with chart of accounts)
    ->  Bank + Bank Account  ->  Warehouse (auto-made per company)

Idempotent: re-running creates nothing new.

    env/bin/python /tmp/bootstrap_masters.py
"""
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe

SITE = "frontend"
COMPANY = "SHRDC"
ABBR = "SHRDC"
COUNTRY = "Malaysia"
CURRENCY = "MYR"


def log(msg):
	print("MARK %s" % msg)


def ensure_customer_group():
	if not frappe.db.exists("Customer Group", "All Customer Groups"):
		frappe.get_doc(
			{
				"doctype": "Customer Group",
				"customer_group_name": "All Customer Groups",
				"is_group": 1,
				"parent_customer_group": "",
			}
		).insert(ignore_permissions=True)
		frappe.db.commit()
		log("customer group root created")
	if frappe.db.exists("Customer Group", "Individual"):
		log("customer group Individual exists")
		return
	frappe.get_doc(
		{
			"doctype": "Customer Group",
			"customer_group_name": "Individual",
			"is_group": 0,
			"parent_customer_group": "All Customer Groups",
		}
	).insert(ignore_permissions=True)
	frappe.db.commit()
	log("customer group Individual created")


def ensure_territory():
	if not frappe.db.exists("Territory", "All Territories"):
		frappe.get_doc(
			{"doctype": "Territory", "territory_name": "All Territories", "is_group": 1}
		).insert(ignore_permissions=True)
		frappe.db.commit()
		log("territory root created")
	if frappe.db.exists("Territory", "Rest Of The World"):
		log("territory Rest Of The World exists")
		return
	frappe.get_doc(
		{
			"doctype": "Territory",
			"territory_name": "Rest Of The World",
			"is_group": 0,
			"parent_territory": "All Territories",
		}
	).insert(ignore_permissions=True)
	frappe.db.commit()
	log("territory Rest Of The World created")


def ensure_price_list():
	for name, selling in (("Standard Selling", 1), ("Standard Buying", 0)):
		if frappe.db.exists("Price List", name):
			log("price list %s exists" % name)
			continue
		frappe.get_doc(
			{
				"doctype": "Price List",
				"price_list_name": name,
				"enabled": 1,
				"selling": selling,
				"buying": 0 if selling else 1,
				"currency": CURRENCY,
			}
		).insert(ignore_permissions=True)
		frappe.db.commit()
		log("price list %s created" % name)


def ensure_fiscal_year():
	"""Sales Orders need a fiscal year covering their transaction date.

	Without one, inserting an order raises
	    FiscalYearError: Date 2026-10-22 is not in any active Fiscal Year
	Create a few consecutive years so imported orders from different dates work.
	"""
	for year in (2025, 2026, 2027):
		name = str(year)
		if frappe.db.exists("Fiscal Year", name):
			log("fiscal year %s exists" % name)
			continue
		try:
			frappe.get_doc(
				{
					"doctype": "Fiscal Year",
					"year": name,
					"year_start_date": "%d-01-01" % year,
					"year_end_date": "%d-12-31" % year,
				}
			).insert(ignore_permissions=True)
			frappe.db.commit()
			log("fiscal year %s created" % name)
		except Exception as exc:
			log("fiscal year %s skipped: %s" % (name, exc))


def ensure_global_defaults(company):
	"""Set the Global Defaults the shopify app implicitly relies on.

	shopify.create_order / retrieve_order build a Sales Order WITHOUT setting
	`company`, so ERPNext's item validation raises "Please specify Company".
	On a wizard-built site this works because Global Defaults carry the
	company; here we set them explicitly.
	"""
	pairs = {
		"company": company.name,
		"currency": CURRENCY,
		"selling_price_list": "Standard Selling",
		"buying_price_list": "Standard Buying",
		"country": COUNTRY,
	}
	for key, value in pairs.items():
		if not value:
			continue
		frappe.defaults.set_global_default(key, value)
		log("global default %s = %s" % (key, value))
	frappe.db.commit()


def ensure_warehouse_types():
	"""ERPNext's Company insert references Warehouse Type 'Transit'.

	On a site built without the setup wizard those records do not exist, and
	Company.insert() dies with:
	    LinkValidationError: Could not find Warehouse Type: Transit
	The wizard normally creates them, so create them here.
	"""
	for wt in ("Transit", "Default"):
		if frappe.db.exists("Warehouse Type", wt):
			log("warehouse type %s exists" % wt)
			continue
		doc = frappe.new_doc("Warehouse Type")
		doc.name = wt  # autoname is prompt/set-by-user, so it must be supplied
		doc.warehouse_type = wt
		doc.flags.ignore_permissions = True
		doc.insert()
		frappe.db.commit()
		log("warehouse type %s created" % wt)


def ensure_uom():
	if frappe.db.exists("UOM", "Nos"):
		log("uom Nos exists")
		return
	frappe.get_doc({"doctype": "UOM", "uom_name": "Nos", "must_be_whole_number": 1}).insert(
		ignore_permissions=True
	)
	frappe.db.commit()
	log("uom Nos created")


def ensure_item_group():
	if not frappe.db.exists("Item Group", "All Item Groups"):
		frappe.get_doc(
			{
				"doctype": "Item Group",
				"item_group_name": "All Item Groups",
				"is_group": 1,
				"parent_item_group": "",
			}
		).insert(ignore_permissions=True)
		frappe.db.commit()
		log("item group root created")
	if frappe.db.exists("Item Group", "Products"):
		log("item group Products exists")
		return
	root = "All Item Groups" if frappe.db.exists("Item Group", "All Item Groups") else None
	frappe.get_doc(
		{
			"doctype": "Item Group",
			"item_group_name": "Products",
			"is_group": 0,
			"parent_item_group": root,
		}
	).insert(ignore_permissions=True)
	frappe.db.commit()
	log("item group Products created")


def ensure_company():
	if frappe.db.exists("Company", COMPANY):
		log("company exists")
		return frappe.get_doc("Company", COMPANY)
	doc = frappe.get_doc(
		{
			"doctype": "Company",
			"company_name": COMPANY,
			"abbr": ABBR,
			"country": COUNTRY,
			"default_currency": CURRENCY,
		}
	)
	# Let ERPNext build its default chart of accounts.
	doc.insert(ignore_permissions=True)
	frappe.db.commit()
	log("company created: %s" % doc.name)
	return frappe.get_doc("Company", COMPANY)


def ensure_bank_account(company):
	"""Ensure a Bank-type GL account + a Bank Account on it.

	Shopify Access.bank_account is a Link to **Account** (the GL account), NOT
	to the Bank Account doctype - even though its label says "Bank Account".
	Pointing it at a Bank Account name fails with
	"Could not find Bank Account: <name>".
	"""
	# 1. a leaf GL account of type Bank
	gl_account = frappe.db.get_value(
		"Account", {"company": company.name, "account_type": "Bank", "is_group": 0}, "name"
	)
	if not gl_account:
		parent = frappe.db.get_value(
			"Account",
			{"company": company.name, "is_group": 1, "account_name": "Bank Accounts"},
			"name",
		)
		if not parent:
			parent = frappe.db.get_value(
				"Account", {"company": company.name, "is_group": 1}, "name"
			)
		if not parent:
			log("NO group account to nest a Bank account under")
			return None
		acc = frappe.get_doc(
			{
				"doctype": "Account",
				"account_name": "SHRDC Bank",
				"parent_account": parent,
				"company": company.name,
				"account_type": "Bank",
				"is_group": 0,
			}
		)
		acc.insert(ignore_permissions=True)
		frappe.db.commit()
		gl_account = acc.name
		log("bank GL account created: %s (parent %s)" % (gl_account, parent))
	else:
		log("bank GL account exists: %s" % gl_account)

	# 2. the Bank Account document on top of it
	existing = frappe.db.get_value("Bank Account", {"company": company.name}, "name")
	if existing:
		current_gl = frappe.db.get_value("Bank Account", existing, "account")
		current_type = frappe.db.get_value("Account", current_gl, "account_type") if current_gl else None
		if current_gl == gl_account or current_type == "Bank":
			log("bank account exists: %s (gl %s)" % (existing, current_gl))
			return current_gl
		# An earlier pass bound it to a non-Bank leaf; rebuild it on the good one.
		log("bank account %s points at %s (%s) - recreating on %s"
		    % (existing, current_gl, current_type, gl_account))
		frappe.delete_doc("Bank Account", existing, force=1, ignore_permissions=True)
		frappe.db.commit()

	if not frappe.db.exists("Bank", "Maybank"):
		frappe.get_doc({"doctype": "Bank", "bank_name": "Maybank"}).insert(ignore_permissions=True)
		frappe.db.commit()

	doc = frappe.get_doc(
		{
			"doctype": "Bank Account",
			"account_name": "SHRDC Bank",
			"bank": "Maybank",
			"account": gl_account,
			"company": company.name,
			"is_default": 1,
		}
	)
	doc.insert(ignore_permissions=True)
	frappe.db.commit()
	log("bank account created: %s (gl %s)" % (doc.name, gl_account))
	return gl_account


def main() -> int:
	frappe.init(site=SITE, sites_path=".")
	frappe.connect()
	frappe.set_user("Administrator")

	ensure_warehouse_types()
	ensure_uom()
	ensure_item_group()
	ensure_customer_group()
	ensure_territory()
	ensure_price_list()
	company = ensure_company()
	ensure_bank_account(company)
	ensure_fiscal_year()
	ensure_global_defaults(company)

	# quick inventory so the caller can see what exists
	for dt in ("Company", "UOM", "Item Group", "Warehouse", "Bank Account", "Account"):
		log("%s count = %s" % (dt, frappe.db.count(dt)))

	frappe.destroy()
	return 0


if __name__ == "__main__":
	sys.exit(main())
