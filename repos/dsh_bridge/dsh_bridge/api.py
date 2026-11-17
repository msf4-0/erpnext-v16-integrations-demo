import frappe

@frappe.whitelist(allow_guest=False)
def handle_a2ui_action():
    """Receives button click actions from the rendered A2UI cards."""
    # form_dict captures both GET query parameters and POST JSON body values
    action_type = frappe.local.form_dict.get("action_type")
    card_id = frappe.local.form_dict.get("card_id")
    
    # Process your logic here...
    
    return {"status": "success", "processed_action": action_type}