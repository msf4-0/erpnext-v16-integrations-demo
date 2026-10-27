import frappe

from shopify.retrieve_order import retrieve_shopify_orders
from shopify.utils import get_shopify_access


@frappe.whitelist()
def execute():
    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return

    try:
        retrieve_shopify_orders(
            shopify_doc.api_key,
            shopify_doc.access_token,
            shopify_doc.shopify_url,
        )
    except Exception:
        frappe.log_error(
            title="Shopify Automated Orders Execution Error",
            message=frappe.get_traceback(),
        )
