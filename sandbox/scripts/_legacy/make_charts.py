import frappe, json

def make_chart(chart_name, doc_type, group_by, viz="Bar", filters="[]"):
    if frappe.db.exists("Dashboard Chart", chart_name):
        frappe.delete_doc("Dashboard Chart", chart_name, ignore_permissions=True)
    c = frappe.new_doc("Dashboard Chart")
    c.chart_name = chart_name
    c.chart_type = "Group By"
    c.document_type = doc_type
    c.group_by_type = "Count"
    c.group_by_based_on = group_by
    c.type = viz
    c.filters_json = filters
    c.timespan = "Select Date Range"
    c.number_of_groups = 0
    c.is_public = 1
    c.module = "Item Tracking"
    c.insert(ignore_permissions=True)
    return c.name

make_chart("Sales Orders by Status", "Sales Order", "status", viz="Pie")
make_chart("Purchase Orders by Status", "Purchase Order", "status", viz="Bar")
make_chart("Job Cards by Workstation", "Job Card", "workstation", viz="Bar")
make_chart("Completed Job Cards by Workstation", "Job Card", "workstation", viz="Bar", filters='[["Job Card","status","=","Completed"]]')

content = json.dumps([
    {"id": "h1", "type": "header", "data": {"text": "<span class='h4'><b>Sales & Purchasing</b></span>", "col": 12}},
    {"id": "c1", "type": "chart", "data": {"chart_name": "Sales Orders by Status", "col": 6}},
    {"id": "c2", "type": "chart", "data": {"chart_name": "Purchase Orders by Status", "col": 6}},
    {"id": "h2", "type": "header", "data": {"text": "<span class='h4'><b>Manufacturing</b></span>", "col": 12}},
    {"id": "c3", "type": "chart", "data": {"chart_name": "Job Cards by Workstation", "col": 6}},
    {"id": "c4", "type": "chart", "data": {"chart_name": "Completed Job Cards by Workstation", "col": 6}},
])
ws = frappe.get_doc("Workspace", "Metabase")
ws.content = content
ws.title = "Monitoring Dashboard"
ws.save(ignore_permissions=True)

frappe.db.commit()
print("DONE charts created + workspace updated")
