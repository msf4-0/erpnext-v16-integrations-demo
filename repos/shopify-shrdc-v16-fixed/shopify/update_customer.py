import requests
import frappe
import json
from shopify.utils import get_shopify_access, is_sync_paused, handle_response, parse_shopify_error

@frappe.whitelist()
def update_shopify_customer_by_email(shopifyCustomerId, firstName, lastName, mobileNum, emailID, address, addrCity, addrState, addrPostcode, customerNotes, customerTags, shopify_url, access_token):
    # Find Shopify customer by shopify customer id
    
    if not shopifyCustomerId:
        frappe.msgprint("customer not found in shopify")
        return
    
    customer_payload = { 
        "id": shopifyCustomerId,
        "first_name": firstName,
        "last_name": lastName,
        "email": emailID,
        "note": customerNotes,
        "tags": customerTags,
        "currency": "MYR",
    }
    if mobileNum:
        customer_payload["phone"] = "+60" + mobileNum

    if address:
        customer_payload["addresses"] = [{
            "address1": address,
            "city": addrCity,
            "province": addrState,
            "country": "Malaysia",
            "zip": addrPostcode
        }]
    payload = {
        "customer": customer_payload
    }

    endpoint = f'customers/{shopifyCustomerId}.json'
    final_url = shopify_url + endpoint

    headers = {
        'Content-Type': 'application/json',
        'X-Shopify-Access-Token': access_token
    }

    try:
        response = requests.put(final_url, json=payload, headers=headers)
        if response.status_code == 200:
            frappe.msgprint(f"Customer record was updated in Shopify.")
        else:
            # Log only: a Shopify rejection must never surface as a dialog while
            # someone is editing a Customer in ERPNext.
            frappe.log_error(
                title="Shopify Customer Update Failed",
                message="Customer %s: HTTP %s %s" % (emailID, response.status_code, parse_shopify_error(response)),
            )
            handle_response(response, "update customer %s" % emailID)
    except requests.exceptions.RequestException as e:
        frappe.log_error(
            title="Shopify Customer Update Failed",
            message=str(e),
        )

def on_submit(doc, method):
    if getattr(doc.flags, "ignore_shopify_update", False):
        return
    if getattr(doc.flags, "in_insert", False):
        return
    if is_sync_paused():
        return

    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return

    update_shopify_customer_by_email(
        doc.shopify_customer_id,
        doc.customer_name,
        "", 
        doc.mobile_no if hasattr(doc, "mobile_no") else "",
        doc.email_id if hasattr(doc, "email_id") else "",
        doc.customer_address if hasattr(doc, "customer_address") else "",
        getattr(doc, "city", ""),
        getattr(doc, "state", ""),
        getattr(doc, "postcode", ""),
        getattr(doc, "notes", ""),
        getattr(doc, "customer_tags", ""),
        shopify_doc.shopify_url,
        shopify_doc.access_token
    )