import frappe
import requests

from shopify.utils import get_shopify_access


def retrieve_shopify_product(api_key, password, shopify_url):
    headers = {
        "X-Shopify-Access-Token": password,
        "Content-Type": "application/json",
    }

    frappe.logger().info("Starting full Shopify product sync")

    url = f"{shopify_url}products.json?limit=250"


    while url:
        response = requests.get(url, headers=headers)

        if response.status_code != 200:
            frappe.log_error(
                f"Shopify fetch failed: {response.status_code} - {response.text}"
            )
            break

        data = response.json()
        products = data.get("products", [])

        for product in products:
            _upsert_item_from_shopify(product)
            frappe.logger().info(
                f"Synced product {product.get('title')} ({product.get('id')})"
            )
        frappe.db.commit()
        # Pagination handling
        link_header = response.headers.get("Link")
        url = None

        if link_header:
            for part in link_header.split(","):
                if 'rel="next"' in part:
                    url = part.split(";")[0].strip("<> ")
                    break

    frappe.logger().info("Shopify product sync completed")


def _get_item_group():
    if frappe.db.exists("Item Group", "Products"):
        return "Products"
    groups = frappe.get_all(
        "Item Group", filters={"is_group": 0}, limit=1, pluck="name"
    )
    return groups[0] if groups else "All Item Groups"


def _upsert_item_from_shopify(product):
    shopify_product_id = str(product.get("id"))
    title = product.get("title")
    description = product.get("body_html") or ""

    # Use the first variant for SKU & inventory
    variant = (product.get("variants") or [{}])[0]
    item_code = variant.get("sku") or f"{shopify_product_id}"

    # Check if Item already exists using Item Code
    existing_item = frappe.db.get_value(
        "Item", {"item_code": item_code}, "name"
    )

    if existing_item:
        item = frappe.get_doc("Item", existing_item)
        item.item_name = title
        item.description = description
        if not item.shopify_product_id:
            item.shopify_product_id = shopify_product_id
        item.flags.ignore_shopify_update = True
        item.save(ignore_permissions=True)
        frappe.logger().info(f"Updated existing Item: {existing_item}")
      
    else:
        #  Create new item
        # Make sure item_code is unique
        item = frappe.new_doc("Item")
        item.item_code = item_code
        item.shopify_product_id = shopify_product_id
        item.item_name = title
        item.description = description
        item.item_group = _get_item_group()
        item.stock_uom = "Nos"
        item.is_stock_item = 1
        item.flags.ignore_shopify_update = True
        item.insert(ignore_permissions=True)
        frappe.logger().info(f"added item: {product}")

def on_submit():
    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    retrieve_shopify_product(
        shopify_doc.api_key,
        shopify_doc.access_token,
        shopify_doc.shopify_url,
    )
