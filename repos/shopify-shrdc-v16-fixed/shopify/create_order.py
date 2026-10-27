import json
import requests
import frappe
from shopify.utils import get_shopify_access, is_sync_paused, handle_response

@frappe.whitelist()
def create_shopify_order(customer_email, items, shopify_url, access_token, sales_order_name=None):
    if isinstance(items, str):
        items = json.loads(items or "[]")

    line_items = []
    for item in items or []:
        price = float(item.get("price") or 0)
        quantity = int(item.get("quantity") or 1)
        line_item = {
            "title": item.get("title") or item.get("sku"),
            "price": price,
            "quantity": quantity,
            "sku": item.get("sku"),
            "tax_lines": [
                {
                    "price": price / 10,
                    "rate": 0.1,
                    "title": "SST",
                }
            ],
        }
        product_id = item.get("product_id")
        if product_id:
            line_item["product_id"] = int(product_id) if str(product_id).isdigit() else product_id
        line_items.append(line_item)

    if not line_items:
        frappe.log_error("Shopify order sync skipped: no line items.", "Shopify Order Create")
        return None

    payload = {
        "order": {
            "email": customer_email,
            "financial_status": "pending",
            "fulfillment_status": "unfulfilled",
            "line_items": line_items,
        }
    }

    headers = {
        "Content-Type": "application/json",
        "X-Shopify-Access-Token": access_token
    }

    final_url = f"{shopify_url}orders.json"
    shopify_order = None

    try:
        response = requests.post(final_url, json=payload, headers=headers, timeout=30)
    except requests.RequestException:
        frappe.log_error(
            title="Shopify Order Create Failed",
            message=frappe.get_traceback(),
        )
        return None

    if response.status_code == 201:
        frappe.msgprint("Order created in Shopify.")
        shopify_order = response.json().get("order")
        if shopify_order and sales_order_name:
            frappe.db.set_value(
                "Sales Order",
                sales_order_name,
                "shopify_order_id",
                shopify_order.get("id"),
            )
    else:
        frappe.log_error(
            title="Shopify Order Create Failed",
            message=f"Status: {response.status_code}\n{response.text}",
        )
        # Log only (see utils.handle_response): no dialog on the ERPNext form.
        handle_response(response, "create order for %s" % (sales_order_name or customer_email))

    return shopify_order.get("id") if shopify_order else None

def on_submit(doc, method):
    if doc.shopify_order_id:
        return
    if is_sync_paused():
        return

    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return

    customer_email = frappe.db.get_value("Customer", doc.customer, "email_id")
    if not customer_email:
        frappe.log_error(
            title="Shopify Order Create Skipped",
            message=f"Customer {doc.customer} has no email address.",
        )
        return

    items = []
    for item in doc.items:
        product_id = frappe.db.get_value("Item", item.item_code, "shopify_product_id") or ""
        item_dict = {
            "title": item.item_name or item.item_code,
            "price": float(item.rate),
            "quantity": int(item.qty),
            "product_id": product_id,
            "sku": item.item_code,
        }
        items.append(item_dict)

    shopify_order_id = create_shopify_order(
        customer_email,
        json.dumps(items),
        shopify_doc.shopify_url,
        shopify_doc.access_token,
        sales_order_name=doc.name,
    )

    if shopify_order_id:
        doc.db_set("shopify_order_id", shopify_order_id)

def clear_shopify_id_on_amend(doc, method):
    if doc.amended_from:
        doc.shopify_order_id = None
        