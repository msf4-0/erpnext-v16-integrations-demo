import requests
import frappe
import json
from shopify.utils import get_shopify_access

@frappe.whitelist()
def cancel_shopify_order(orderID, shopify_url,access_token):

    # Shopify API headers and endpoint
    headers = {
        "Content-Type": "application/json",
        "X-Shopify-Access-Token": access_token
    }
    final_url = f"{shopify_url}orders/{orderID}/cancel.json"

    # Send the POST request to create the product
    response = requests.post(final_url, headers=headers)

    if response.status_code == 200:
        frappe.msgprint(f"Order was successfully cancelled in Shopify.")
    else:
        frappe.msgprint(f"Failed to delete the order in Shopify. Error: {response.content}")

# Attach the custom function to the 'Item' doctype's on_submit event
def on_submit(doc, method):
    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    cancel_shopify_order(doc.shopify_order_id, shopify_doc.shopify_url, shopify_doc.access_token)