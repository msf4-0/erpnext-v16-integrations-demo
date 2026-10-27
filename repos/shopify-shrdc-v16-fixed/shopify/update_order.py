import requests
import frappe
import json
from shopify.utils import get_shopify_access, is_sync_paused, handle_response, parse_shopify_error

@frappe.whitelist()
def update_shopify_order(orderID, status, shopify_url,access_token):

    paid_status = ""
    fulfil_status = ""
    if status == "To Deliver":
        paid_status = "paid"
        fulfil_status = "unfulfilled"
    elif status == "To Deliver and Bill":
        paid_status = "pending"
        fulfil_status = "unfulfilled"
    elif status == "Draft":
        paid_status = "pending"
        fulfil_status = "unfulfilled"
    elif status == "Completed":
        paid_status = "paid"
        fulfil_status = "fulfilled"

    # Construct the API payload
    payload = {
        "order": {
            "id": str(orderID),
            "tags": "best, on-time",
            "financial_status": paid_status,
            "fulfillment_status": fulfil_status,
        }
    }

    payload_json = json.dumps(payload)

    headers = {
        "Content-Type": "application/json",
        "X-Shopify-Access-Token": access_token
    }

    final_url = f"{shopify_url}orders/{orderID}.json"


    try:
        # Send the PUT request to create the product
        response = requests.put(final_url, data=payload_json, headers=headers)

        if response.status_code == 200:
            frappe.msgprint(f"Order was succefully updated in Shopify.")
        else:
            # Log only: never interrupt an ERPNext save with a Shopify error.
            frappe.log_error(
                title="Shopify Order Update Failed",
                message="Order %s: HTTP %s %s" % (orderID, response.status_code, parse_shopify_error(response)),
            )
            handle_response(response, "update order %s" % orderID)

    except requests.exceptions.RequestException as e:
        frappe.log_error(
            title="Shopify Order Update Failed",
            message=str(e),
        )

# Attach the custom function to the 'Item' doctype's on_submit event
def on_submit(doc, method):

    if not doc.shopify_order_id:
        return
    
    if doc.amended_from:
        return

    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    update_shopify_order(doc.shopify_order_id, doc.status, shopify_doc.shopify_url, shopify_doc.access_token)
