import requests
import frappe
import json
from shopify.utils import get_shopify_access

@frappe.whitelist()
def update_shopify_product(item_code, shopify_id, api_link, qty, access_token=None):
    """Push a stock qty to the Shopify variant.

    NOTE: this used to send NO X-Shopify-Access-Token header at all, so every
    call came back 401 no matter how good the token was. The token is now taken
    from `shopify.auth` (minted on demand) unless the caller passes one.
    """
    if not access_token:
        try:
            from shopify.auth import get_access_token

            access_token = get_access_token()
        except Exception:
            access_token = None

    # Construct the API payload
    payload = {
        "product": {
            "vendor": "TD Furniture",
            "variants": [
                {
                    "sku": item_code,
                    "weight_unit": "kg",
                    "inventory_management": "shopify",
                    "inventory_quantity": qty,
                }
            ]
        }
    }

    payload_json = json.dumps(payload)

    endpoint = 'products/' + str(shopify_id) + '.json'
    headers = {
        'Content-Type': 'application/json',
    }
    if access_token:
        headers['X-Shopify-Access-Token'] = access_token
    final_url = api_link + endpoint

    # Send the PUT request to create the product
    response = requests.put(final_url, data=payload_json, headers=headers, timeout=30)

    if response.status_code == 200:
        frappe.msgprint(f"Product Quantity updated in Shopify.")
    else:
        # Log, never raise: a stock post must not fail because Shopify is down.
        from shopify.utils import handle_response, parse_shopify_error

        if handle_response(response, "inventory update %s" % item_code):
            frappe.log_error(
                title="Shopify inventory update failed",
                message="%s: HTTP %s %s" % (item_code, response.status_code, parse_shopify_error(response)),
            )
        

def on_submit(doc, method):
    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    update_shopify_product(doc.item_code, doc.shopify_product_id, doc.api_link, doc.actual_qty)