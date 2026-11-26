import os, sys, importlib
os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")
import frappe
frappe.init(site="frontend", sites_path=".")
frappe.connect()
frappe.set_user("Administrator")

print("=== sys.path (apps-related) ===")
for p in sys.path:
    if "apps" in p or "bench" in p:
        print("  ", p)

print("=== DocType module field ===")
print("Stock Entry Tracked Item module =", frappe.db.get_value("DocType", "Stock Entry Tracked Item", "module"))

from frappe.modules.utils import get_module_name, get_app, scrub
mod = frappe.db.get_value("DocType", "Stock Entry Tracked Item", "module")
print("get_app(mod) =", get_app(mod))
print("get_module_name =", get_module_name("Stock Entry Tracked Item", mod))

print("=== step-by-step import ===")
for name in ["item_tracking", "item_tracking.item_tracking", "item_tracking.item_tracking.doctype", "item_tracking.item_tracking.doctype.stock_entry_tracked_item"]:
    try:
        importlib.import_module(name)
        print("  OK   %s" % name)
    except Exception as e:
        print("  FAIL %s -> %s" % (name, e))

print("=== filesystem check ===")
base = "/home/frappe/frappe-bench/apps/item_tracking"
for rel in ["__init__.py", "item_tracking/__init__.py", "item_tracking/item_tracking/__init__.py", "item_tracking/item_tracking/doctype/__init__.py", "item_tracking/item_tracking/doctype/stock_entry_tracked_item/__init__.py"]:
    p = os.path.join(base, rel)
    print("  %s exists=%s" % (rel, os.path.exists(p)))
