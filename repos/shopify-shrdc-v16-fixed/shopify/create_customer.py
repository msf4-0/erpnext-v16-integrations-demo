import requests
import frappe
from shopify.utils import get_shopify_access, is_sync_paused, handle_response, parse_shopify_error

@frappe.whitelist()
def create_shopify_customer(firstName, lastName, mobileNum, emailID, address, addrCity, addrState, addrPostcode, shopify_url, access_token):

    # Prepare payload
    customer_payload = {
        "email": emailID,
        "accepts_marketing": True,
        "first_name": firstName,
        "last_name": lastName,
        "orders_count": 0,
        "note": "",
        "tax_exempt": False,
        "tags": "",
        "currency": "MYR",
        "phone": "+60" + mobileNum if mobileNum else "",
        "addresses": [
            {
                "address1": address,
                "city": addrCity,
                "province": addrState,
                "country": "Malaysia",
                "zip": addrPostcode,
                "default": True,
            }
        ],
    }

    payload = {
        "customer": customer_payload
    }

    headers = {
        "Content-Type": "application/json",
        "X-Shopify-Access-Token": access_token
    }
    final_url = f"{shopify_url}customers.json"
    response = requests.post(
        final_url,
        json=payload,
        headers=headers,
        timeout=30,
    )

    if response.status_code != 201:
        frappe.log_error(
            title="Shopify Customer Creation Failed",
            message="Customer %s: HTTP %s %s" % (firstName, response.status_code, parse_shopify_error(response)),
        )
        # Never block the ERPNext save: a rejected token pauses the sync, any
        # other failure is logged and the Customer is kept locally.
        handle_response(response, "create customer %s" % firstName)
        return None

    frappe.msgprint(f"Customer {firstName} created in Shopify.")

    customer = response.json()["customer"]

    return customer["id"]

def on_submit(doc, method):
    if getattr(doc.flags, "ignore_shopify_update", False):
        return
    if doc.shopify_customer_id:
        return
    if is_sync_paused():
        return

    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    try:
        customer = create_shopify_customer(
            doc.customer_name,
            "",
            doc.mobile_no if hasattr(doc, "mobile_no") else "",
            doc.email_id if hasattr(doc, "email_id") else "",
            doc.customer_address if hasattr(doc, "customer_address") else "",
            "",
            "",
            "",
            shopify_doc.shopify_url,
            shopify_doc.access_token,
        )
    except Exception:
        frappe.log_error(
            title="Shopify Customer Create Failed",
            message=f"Customer: {doc.name}\n{frappe.get_traceback()}",
        )
        return

    if customer:
        doc.db_set("shopify_customer_id", customer)