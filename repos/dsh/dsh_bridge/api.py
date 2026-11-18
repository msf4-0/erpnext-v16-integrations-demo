import frappe
from frappe import _

@frappe.whitelist(allow_guest=False)
def handle_a2ui_action():
    try:
        # Parse incoming data from the request
        data = frappe.local.form_dict
        action = data.get("action")
        
        if not action:
            frappe.throw(_("Missing required parameter: 'action'"), title=_("Invalid Request"))
            
        # Example business logic / plugin execution
        result = process_action_logic(action)
        
        return {
            "status": "success",
            "message": "Action processed successfully",
            "data": result
        }

    except frappe.ValidationError as e:
        # Catch business logic / validation failures gracefully
        frappe.local.response["http_status_code"] = 417
        return {
            "status": "error",
            "message": str(e)
        }
    except Exception as e:
        # Catch unexpected server exceptions safely
        frappe.log_error(frappe.get_traceback(), "DSH Bridge Action Error")
        frappe.local.response["http_status_code"] = 500
        return {
            "status": "error",
            "message": "An internal error occurred while processing the action."
        }

@frappe.whitelist()
def handle_chat():
    """
    Receives chat prompt and ERP context from the A2UI React frontend,
    routes it to the DSH orchestrator, and returns the response.
    """
    data = frappe.safe_eval(frappe.request.data) if frappe.request.data else frappe.form_dict
    prompt = data.get("prompt")
    company = data.get("company") or frappe.defaults.get_user_default("Company")
    user = frappe.session.user

    if not prompt:
        frappe.local.response["http_status_code"] = 417
        return {"error": "Prompt parameter is required."}

    # --- DSH Orchestrator Integration Hook ---
    reply_text = f"DSH Orchestrator received: '{prompt}' for user {user} under company '{company}'."

    return {
        "status": "success",
        "reply": reply_text,
        "a2ui_card": None
    }

def process_action_logic(action):
    # Your custom plugin logic here
    return {"processed_action": action}