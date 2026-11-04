import os, sys
os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")
import frappe
frappe.init(site="frontend", sites_path=".")
frappe.connect()
frappe.set_user("Administrator")
print("item exists:", frappe.db.exists("Item", "GKRT-001"))
print("boms for GKRT-001:", frappe.db.get_all("BOM", filters={"item": "GKRT-001"}, fields=["name", "docstatus", "is_default"]))
print("all boms:", frappe.db.get_all("BOM", fields=["name", "item", "docstatus", "is_default"], limit=100))
print("item default_bom:", frappe.db.get_value("Item", "GKRT-001", "default_bom"))
print("items:", frappe.db.get_all("Item", filters={"item_code": ["in", ["GKRT-001","WHL-001","HST-001","SET-001","FRM-001","STR-001"]]}, fields=["item_code","item_name","default_bom"]))
