import frappe, traceback
try:
    r = frappe.call("metabase_integration.metabase_integration.doctype.metabase_dashboard.get_url", dashboard="ERPNext Monitoring")
    print("URL:", r)
except Exception:
    traceback.print_exc()
