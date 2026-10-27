import requests
import frappe
import json
from shopify.utils import get_shopify_access

@frappe.whitelist()
def delete_shopify_customer(customerID, shopify_url,access_token):

    headers = {
        "Content-Type": "application/json",
        "X-Shopify-Access-Token": access_token
    }
    response = requests.delete(
        f"{shopify_url}customers/{customerID}.json",
        headers=headers
    )
    response.raise_for_status() 

    if response.status_code == 200:
        frappe.msgprint(f"Customer record was deleted from Shopify.")
    else:
        frappe.msgprint(f"Failed to delete the customer in Shopify. Error: {response.content}")

# Attach the custom function to the 'Item' doctype's on_submit event
def on_submit(doc, method):
    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    delete_shopify_customer(doc.shopify_customer_id, shopify_doc.shopify_url, shopify_doc.access_token)

