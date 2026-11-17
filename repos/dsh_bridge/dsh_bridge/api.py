import frappe

@frappe.whitelist(allow_guest=False)
def handle_a2ui_action():
    """Receives button click actions from the rendered A2UI cards."""
    data = frappe.local.form_dict
    # Process the action (e.g., create a Sales Order using frappe.get_doc)
    return {"status": "success", "message": "Action processed by ERPNext"}
