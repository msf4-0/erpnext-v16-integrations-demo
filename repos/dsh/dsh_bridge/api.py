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

@frappe.whitelist(allow_guest=False)
def handle_chat():
    """
    Receives chat prompt and ERP context from the A2UI React frontend,
    routes it to the DSH orchestrator, and returns the response.
    """
    # frappe.request.data is bytes and only exists on an HTTP call; bench/RQ
    # calls fall back to form_dict. safe_eval would choke on bytes and on JSON
    # literals (null/true), so parse JSON properly.
    request = getattr(frappe.local, "request", None)
    raw = getattr(request, "data", None) if request else None
    data = frappe.parse_json(raw.decode("utf-8")) if raw else frappe.form_dict
    data = data or {}

    prompt = (data.get("prompt") or "").strip()
    company = data.get("company") or frappe.defaults.get_user_default("Company")
    user = frappe.session.user

    if not prompt:
        frappe.local.response["http_status_code"] = 417
        return {"status": "error", "reply": "Prompt parameter is required."}

    try:
        # --- mock orchestrator: live stock lookup ---------------------------
        if "inventory" in prompt.lower() or "stock" in prompt.lower():
            rows = frappe.db.sql(
                """
                SELECT
                    b.item_code,
                    i.item_name,
                    b.warehouse,
                    b.actual_qty,
                    b.stock_uom
                FROM `tabBin` b
                LEFT JOIN `tabItem` i ON i.name = b.item_code
                WHERE b.actual_qty <> 0
                ORDER BY b.actual_qty DESC
                LIMIT 5
                """,
                as_dict=True,
            )

            return {
                "status": "success",
                "reply": f"Fetched live stock levels for {user}"
                + (f" ({company})" if company else "")
                + f": {len(rows)} item(s)",
                "card_type": "inventory_table",
                "columns": [
                    ["item_code", "Item"],
                    ["item_name", "Name"],
                    ["warehouse", "Warehouse"],
                    ["actual_qty", "Qty"],
                    ["stock_uom", "UOM"],
                ],
                "data": rows,
            }

        # --- default echo (no DSH tokens configured) ------------------------
        return {
            "status": "success",
            "reply": (
                f"Echo (No AI Tokens): Received your prompt '{prompt}'. "
                "Try typing 'inventory' to test live database fetching!"
            ),
            "a2ui_card": None,
        }

    except Exception:
        frappe.log_error(frappe.get_traceback(), "DSH Bridge Chat Error")
        frappe.local.response["http_status_code"] = 500
        return {
            "status": "error",
            "reply": "Backend error while handling the chat prompt. Check Error Log.",
        }

def process_action_logic(action):
    if action == "create_test_order":
        # Example of writing a real record into ERPNext (e.g., ToDo or Sales Order)
        todo = frappe.get_doc({
            "doctype": "ToDo",
            "description": "Created via DSH Assistant Action Button",
            "status": "Open"
        })
        todo.insert(ignore_permissions=True)
        frappe.db.commit()
        return {"created_doctype": "ToDo", "name": todo.name}
        
    return {"processed_action": action}