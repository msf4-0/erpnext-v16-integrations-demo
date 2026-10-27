import frappe
from shopify.retrieve_product import retrieve_shopify_product
from shopify.retrieve_customer import retrieve_shopify_customers
from shopify.utils import get_shopify_access
# Map ERPNext Item fields to Shopify status
def get_shopify_status(item):
    if item.get("disabled"):
        return "archived"
    if not item.get("show_in_website", True):
        return "draft"
    return "active"

@frappe.whitelist()
def sync_create_products(shopify_access_name):
    """Push ERPNext Items to Shopify using credentials from Shopify Access"""

    from shopify.create_product import create_shopify_product

    # Fetch Shopify Access credentials automatically. get_shopify_access()
    # stamps a freshly minted client-credentials token onto the doc, so this
    # never pushes with a 24 h-stale token.
    shopify_doc = get_shopify_access(shopify_access_name)
    if not shopify_doc:
        frappe.throw("No Shopify Access record configured")
    shopify_url = shopify_doc.shopify_url       # e.g., https://4e1075.myshopify.com/admin/api/2025-10/
    shopify_api_key = shopify_doc.api_key
    shopify_api_password = shopify_doc.access_token

    # Get all items
    items = frappe.get_all(
        "Item",
        fields=[
            "item_code",
            "item_name",
            "description",
            "standard_rate",
            "weight_per_unit",
            "opening_stock",
            "image",
            "disabled",
            "shopify_product_id"
        ],
        limit_page_length=0,
    )

    for item in items:
        if item.get("shopify_product_id"):
            continue

        status = get_shopify_status(item)

        try:
            create_shopify_product(
                item["item_code"],
                item["item_name"],
                status,
                item.get("description"),
                item.get("standard_rate"),
                item.get("weight_per_unit"),
                item.get("opening_stock"),
                item.get("image"),
                shopify_url,
                shopify_api_key,
                shopify_api_password,
            )
        except Exception:
            frappe.log_error(
                title="Shopify Product Sync Failed",
                message=f"Item: {item.get('item_code')}\n{frappe.get_traceback()}",
            )

    return "OK"

@frappe.whitelist()
def sync_retrieve_products(shopify_access_name):
    """
    Called from ERPNext UI button
    """

    shopify_doc = get_shopify_access(shopify_access_name)
    retrieve_shopify_product(shopify_doc.api_key, shopify_doc.access_token, shopify_doc.shopify_url)

    return "OK" 

@frappe.whitelist()
def sync_retrieve_customers(shopify_access_name):
    """
    Called from ERPNext UI button
    """

    shopify_doc = get_shopify_access(shopify_access_name)
    retrieve_shopify_customers(shopify_doc.api_key, shopify_doc.access_token, shopify_doc.shopify_url)

    return "OK"

import frappe
import json

@frappe.whitelist()
def upsert_item():
    try:
        raw_data = frappe.request.data
        data = json.loads(raw_data.decode("utf-8")) if raw_data else {}
    except Exception:
        frappe.throw("Invalid JSON body")

    # Support wrapped payload: { "data": {...} }
    if isinstance(data, dict) and "data" in data:
        data = data["data"]

    item_code = data.get("item_code")
    if not item_code:
        frappe.throw("item_code is required")

    if frappe.db.exists("Item", item_code):
        item = frappe.get_doc("Item", item_code)
        item.update(data)
        item.save()
    else:
        item = frappe.get_doc({
            "doctype": "Item",
            **data
        })
        item.insert()

    frappe.db.commit()

    return {
        "status": "success",
        "item_code": item_code
    }

# shopify/api.py
import frappe

@frappe.whitelist()
def delete_item(shopify_product_id):

    if not shopify_product_id:
        frappe.throw("shopify_product_id is required")

    items = frappe.get_all(
        "Item",
        filters={"shopify_product_id": shopify_product_id},
        fields=["name"]
    )

    if not items:
        return {"status": "not_found"}

    for item in items:
        frappe.delete_doc("Item", item["name"], force=1)

    return {
        "status": "deleted",
        "shopify_product_id": shopify_product_id
    }

import frappe
import json

@frappe.whitelist(allow_guest=True)
def update_item():
    try:
        raw_data = frappe.request.data
        data = json.loads(raw_data.decode("utf-8")) if raw_data else {}
    except Exception:
        frappe.throw("Invalid JSON body")

    # Shopify sends the product as the root object
    shopify_product_id = data.get("shopify_product_id")
    if not shopify_product_id:
        frappe.throw("Shopify product ID (id) is required in the webhook payload.")

    # Find the ERPNext Item by shopify_product_id
    item_name = frappe.db.get_value("Item", {"shopify_product_id": str(shopify_product_id)}, "name")
    if not item_name:
        frappe.throw(f"No ERPNext Item found with shopify_product_id {shopify_product_id}")

    # Prepare the fields you want to update
    update_fields = {
        "item_name": data.get("title"),
        "description": data.get("body_html"),
        "image": data["image"]["src"] if data.get("image") else None,
        # Add more mappings as needed
    }

    # Remove None values to avoid overwriting with nulls
    update_fields = {k: v for k, v in update_fields.items() if v is not None}

    # Update the Item
    item = frappe.get_doc("Item", item_name)
    frappe.msgprint(json.dumps(update_fields))
    frappe.msgprint(str(type(update_fields)))

    frappe.flags.from_shopify = True
    item.update(update_fields)
    item.save()
    frappe.db.commit()
    frappe.msgprint("Item saved successfully")


    return {
        "status": "success",
        "item_name": item_name,
        "shopify_product_id": shopify_product_id
    }

# testt