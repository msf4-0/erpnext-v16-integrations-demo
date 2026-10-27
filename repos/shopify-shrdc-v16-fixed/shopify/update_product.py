import requests
import frappe
import json
from shopify.utils import get_shopify_access, is_sync_paused, handle_response, parse_shopify_error

@frappe.whitelist()
def update_shopify_product(productId,itemCode, itemName, itemStatus, itemDescription, price, unitWeight, inventoryNum, shopify_url, access_token, imagePath):
    headers = {
        "X-Shopify-Access-Token": access_token,
        "Content-Type": "application/json"
    }

    # Shopify 422s on null numerics, and int(None) used to raise a TypeError that
    # silently killed the update whenever the item had no opening stock.
    def _num(value, default=0):
        try:
            return default if value in (None, "") else float(value)
        except (TypeError, ValueError):
            return default

    payload = {
        "product": {
            "id": productId,
            "title": itemName,
            "body_html": itemDescription or "",
            "vendor": "TD Furniture",
            "status": itemStatus,
            "variants": [{
                "sku": itemCode,
                "price": _num(price),
                "weight": _num(unitWeight),
                "weight_unit": "kg",
                "inventory_management": "shopify",
                "inventory_quantity": int(_num(inventoryNum))
            }]
        }
    }

    # Update product
    response = requests.put(f"{shopify_url}products/{productId}.json", json=payload, headers=headers, timeout=30)

    if response.status_code == 200:
        # Silent on success: an Item save must not pop a dialog on the form.
        return response.json().get("product", {}).get("id")

    else:
        frappe.log_error(
            title="Shopify Product Update Failed",
            message="SKU %s: HTTP %s %s" % (itemCode, response.status_code, parse_shopify_error(response)),
        )
        # A rejected token pauses the integration; anything else is logged only so
        # editing an Item in ERPNext never raises a red dialog.
        handle_response(response, "update product %s" % itemCode)
        return None

    # Upload image
    if imagePath:
        image_endpoint = f"{shopify_url}products/{productId}/images.json"

        image_payload = {
            "image": {
                "src": imagePath
            }
        }

        image_response = requests.post(
            image_endpoint,
            json=image_payload,
            headers=headers
        )

        if image_response.status_code == 201:
            frappe.msgprint(f"Image updated for product '{itemName}' in Shopify.")
        else:
            frappe.log_error(
                title="Shopify Image Upload Failed",
                message=image_response.text
            )
    



# Attach the custom function to the 'Item' doctype's on_submit event
def on_submit(doc, method):
    if getattr(doc.flags, "ignore_shopify_update", False):
        return
    if getattr(doc.flags, "in_insert", False):
        return
    if not doc.shopify_product_id:
        return
    if is_sync_paused():
        return

    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return

    if doc.disabled:
        status = "archived"
    elif not getattr(doc, "show_in_website", True):
        status = "draft"
    else:
        status = "active"

    try:
        update_shopify_product(
            doc.shopify_product_id,
            doc.item_code,
            doc.item_name,
            status,
            doc.description,
            doc.standard_rate,
            doc.weight_per_unit,
            doc.opening_stock,
            shopify_doc.shopify_url,
            shopify_doc.access_token,
            doc.image,
        )
    except Exception:
        frappe.log_error(
            title="Shopify Product Update Failed",
            message=f"Item: {doc.name}\n{frappe.get_traceback()}",
        )


