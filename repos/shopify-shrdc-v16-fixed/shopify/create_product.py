import requests
import frappe
from shopify.utils import get_shopify_access, is_sync_paused, handle_response, parse_shopify_error


def _money(value, default=0):
    """Shopify rejects null/"" in numeric variant fields with a 422 - coerce."""
    try:
        if value is None or value == "":
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


@frappe.whitelist()
def create_shopify_product(itemCode, itemName, itemStatus, itemDescription, price, unitWeight, inventoryNum, imagePath, shopify_url, api_key, secret_key):
    qty = int(_money(inventoryNum, 0))
    payload = {
        "product": {
            "title": itemName,
            "body_html": itemDescription or "",
            "vendor": "TD Furniture",
            "status": itemStatus,
            "variants": [
                {
                    "price": _money(price, 0),
                    "sku": itemCode,
                    "weight": _money(unitWeight, 0),
                    "inventory_management": "shopify",
                    "weight_unit": "kg",
                    "inventory_quantity": qty,
                    "old_inventory_quantity": qty,
                }
            ]
        }
    }

    
    headers = {
        "Content-Type": "application/json",
        "X-Shopify-Access-Token": secret_key,
    }
    response = requests.post(
        shopify_url + "products.json",
        json=payload,
        headers=headers,
        timeout=30,
    )

    if response.status_code == 201:
        frappe.msgprint(f"Product '{itemName}' created in Shopify.")
        product_data = response.json()
        product_id = product_data["product"]["id"]
        frappe.msgprint(f"Created Shopify product {product_id}")
    else:
        # Never block the ERPNext save: an unreachable Shopify (or a rotated
        # Admin API token) is logged, and 401/403 pauses the sync instead of
        # raising a dialog on every Item save.
        if not handle_response(response, "create product %s" % itemCode):
            return None
        frappe.log_error(
            title="Shopify Product Create Failed",
            message="SKU %s: HTTP %s %s" % (itemCode, response.status_code, parse_shopify_error(response)),
        )
        return None

    return product_id

# Attach the custom function to the 'Item' doctype's on_submit event
def after_insert(doc, method):
    if getattr(doc.flags, "ignore_shopify_update", False):
        return
    if doc.shopify_product_id:
        return
    if is_sync_paused():
        return

    # Fetch Shopify Access credentials
    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return

    shopify_url = shopify_doc.shopify_url
    api_key = shopify_doc.api_key
    secret_key = shopify_doc.access_token

    # Determine Shopify status
    if doc.disabled:
        status = "archived"
    elif not getattr(doc, "show_in_website", True):
        status = "draft"
    else:
        status = "active"

    try:
        product_id = create_shopify_product(
            doc.item_code,
            doc.item_name,
            status,
            doc.description,
            doc.standard_rate,
            doc.weight_per_unit,
            doc.opening_stock,
            doc.image,
            shopify_url,
            api_key,
            secret_key
        )
    except Exception:
        frappe.log_error(
            title="Shopify Product Create Failed",
            message=frappe.get_traceback(),
        )
        return

    if product_id:
        doc.db_set("shopify_product_id", str(product_id))

