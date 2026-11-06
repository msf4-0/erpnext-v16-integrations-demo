import frappe

s = frappe.get_doc("Metabase Settings")
s.metabase_url = "http://localhost:3005"
s.metabase_secret = "8d3ff1ca2ba1e642719167444bb74f6c081b18ecaae74649617d747303647b49"
s.metabase_exp_time = 20
s.save(ignore_permissions=True)
print("Metabase Settings saved:", s.metabase_url)

if not frappe.db.exists("Metabase Dashboard", "ERPNext Monitoring"):
    d = frappe.new_doc("Metabase Dashboard")
    d.dashboard_name = "ERPNext Monitoring"
    d.dashboard_id = 2
    d.is_active = 1
    d.insert(ignore_permissions=True)
    print("Metabase Dashboard created:", d.name, "id", d.dashboard_id)
else:
    print("Metabase Dashboard already exists")

frappe.db.commit()
print("COMMITTED")
