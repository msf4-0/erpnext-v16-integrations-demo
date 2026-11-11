import sys, frappe
frappe.init(site="frontend", sites_path=".")
frappe.connect()
frappe.session.user = "Administrator"
frappe.local.lang = "en"
secret = sys.argv[1]
mburl = sys.argv[2] if len(sys.argv) > 2 else "http://localhost:3005"
print("secret len", len(secret))
st = frappe.get_single("Metabase Settings")
st.metabase_url = mburl
st.metabase_secret = secret
st.metabase_exp_time = 20
st.save(ignore_permissions=True)
print("settings saved:", frappe.db.get_single_value("Metabase Settings", "metabase_url"),
      "secretlen", len(frappe.db.get_single_value("Metabase Settings", "metabase_secret")))
if not frappe.db.exists("Metabase Dashboard", "ERPNext Monitoring"):
    frappe.get_doc({
        "doctype": "Metabase Dashboard", "dashboard_name": "ERPNext Monitoring",
        "dashboard_id": 2, "theme": "Light", "is_active": 1, "show_title": 1,
    }).insert(ignore_permissions=True)
    print("dashboard created")
else:
    print("dashboard exists")
frappe.db.commit()
from metabase_integration.metabase_integration.doctype.metabase_dashboard import get_url
res = get_url("ERPNext Monitoring")
print("iframeUrl", res["iframeUrl"][:60])
