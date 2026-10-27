import requests
import frappe
from frappe.utils import add_days, nowdate
from urllib.parse import quote

from shopify.utils import get_shopify_access


@frappe.whitelist()
def retrieve_shopify_orders(api_key, api_password, shopify_store_url):
    api_endpoint = f"{shopify_store_url}orders.json?status=any&limit=250"

    # Optional lower bound, so a store with real order history does not import
    # every order ever placed on the first scheduled run. Set from site config:
    #   bench --site <site> set-config shopify_order_sync_since \
    #       "2026-10-27T11:30:00+08:00"
    # Unset = previous behaviour (every order, every page).
    _since = frappe.conf.get("shopify_order_sync_since")
    if _since:
        api_endpoint += "&created_at_min=" + quote(str(_since), safe="")

    headers = {
        "X-Shopify-Access-Token": api_password,
        "Content-Type": "application/json",
    }

    while api_endpoint:
        try:
            response = requests.get(api_endpoint, headers=headers, timeout=60)
        except requests.RequestException:
            frappe.log_error(
                title="Shopify Order Fetch Failed",
                message=frappe.get_traceback(),
            )
            break

        if response.status_code != 200:
            frappe.log_error(
                title="Shopify Order Fetch Failed",
                message=f"Status: {response.status_code}\n{response.text}",
            )
            break

        orders_data = response.json().get("orders", [])
        for shopify_order in orders_data:
            try:
                create_sales_order(shopify_order)
            except Exception:
                frappe.log_error(
                    title="Shopify Order Import Failed",
                    message=(
                        f"Shopify order: {shopify_order.get('name')} "
                        f"({shopify_order.get('id')})\n{frappe.get_traceback()}"
                    ),
                )

        frappe.logger().info(
            f"Shopify orders retrieved: {len(orders_data)}"
        )

        api_endpoint = None
        link_header = response.headers.get("Link")
        if link_header:
            for part in link_header.split(","):
                if 'rel="next"' in part:
                    api_endpoint = part.split(";")[0].strip("<> ")
                    break

    frappe.logger().info("Shopify order sync completed")


def create_sales_order(shopify_order):
    shopify_order_id = shopify_order.get("id")
    if not shopify_order_id:
        return
    shopify_order_id = str(shopify_order_id)
    order_name = shopify_order.get("name") or shopify_order_id

    existing_order = frappe.db.get_value(
        "Sales Order",
        {"shopify_order_id": shopify_order_id},
        "name",
    )
    if existing_order:
        return

    customer_data = shopify_order.get("customer") or {}
    email = customer_data.get("email") or shopify_order.get("email") or ""
    shopify_customer_id = customer_data.get("id")
    customer_name = None

    if shopify_customer_id:
        customer_name = frappe.db.get_value(
            "Customer",
            {"shopify_customer_id": str(shopify_customer_id)},
            "name",
        )

    if not customer_name:
        customer_name = create_customer(customer_data, email)

    if not customer_name:
        frappe.logger().warning(
            f"Sales Order {order_name} has no customer. Skipping creation."
        )
        return

    new_sales_order = frappe.new_doc("Sales Order")
    new_sales_order.customer = customer_name
    new_sales_order.delivery_date = add_days(nowdate(), 1)
    new_sales_order.shopify_order_id = shopify_order_id

    for line_item in shopify_order.get("line_items") or []:
        create_sales_order_item(new_sales_order, line_item)

    if not new_sales_order.get("items"):
        frappe.logger().warning(
            f"Sales Order {order_name} has no valid items. Skipping creation."
        )
        return

    new_sales_order.insert(ignore_permissions=True)
    frappe.logger().info(f"Sales Order {new_sales_order.name} created from Shopify")


def _first_leaf(doctype, fallback):
    values = frappe.get_all(
        doctype, filters={"is_group": 0}, pluck="name", limit=1
    )
    return values[0] if values else fallback


def _get_item_group():
    for group in ("Products", "All Item Groups"):
        if frappe.db.exists("Item Group", group):
            return group
    groups = frappe.get_all(
        "Item Group", filters={"is_group": 0}, limit=1, pluck="name"
    )
    return groups[0] if groups else "All Item Groups"


def create_sales_order_item(sales_order, line_item):
    item_code = line_item.get("sku")
    title = line_item.get("title")
    shopify_product_id = str(line_item.get("product_id") or "")

    if not item_code:
        frappe.logger().warning(
            f"Skipping item without SKU (Shopify line_item_id={line_item.get('id')})"
        )
        return

    if not frappe.db.exists("Item", item_code):
        item = frappe.new_doc("Item")
        item.item_code = item_code
        item.item_name = title or item_code
        item.item_group = _get_item_group()
        item.stock_uom = "Nos"
        item.is_stock_item = 1
        item.shopify_product_id = shopify_product_id
        item.insert(ignore_permissions=True)

    qty = line_item.get("quantity")
    price = line_item.get("price")
    qty = int(qty) if qty is not None else 1
    rate = float(price) if price is not None else 0.0

    so_item = sales_order.append("items")
    so_item.item_code = item_code
    so_item.qty = qty
    so_item.rate = rate
    so_item.conversion_factor = 1


def create_customer(shopify_customer, email=None):
    if not shopify_customer and not email:
        return None

    shopify_customer = shopify_customer or {}
    shopify_customer_id = shopify_customer.get("id")
    customer_email = shopify_customer.get("email") or email or ""

    if shopify_customer_id:
        existing_customer = frappe.db.get_value(
            "Customer",
            {"shopify_customer_id": str(shopify_customer_id)},
            "name",
        )
        if existing_customer:
            return existing_customer

    customer_name = (
        f"{shopify_customer.get('first_name') or ''} "
        f"{shopify_customer.get('last_name') or ''}"
    ).strip()
    # Guest checkouts have no name and no email. A bare "Shopify Customer"
    # fallback produced hundreds of identical rows (and "Shopify Customer None"
    # whenever a null leaked into the f-string), so identify guests by id.
    if not customer_name:
        customer_name = customer_email or ("Shopify Guest %s" % str(shopify_customer_id or "")[-4:])

    new_customer = frappe.new_doc("Customer")
    new_customer.customer_name = customer_name
    new_customer.email_id = customer_email
    if shopify_customer_id:
        new_customer.shopify_customer_id = str(shopify_customer_id)
    new_customer.default_currency = "MYR"
    new_customer.default_price_list = "Standard Selling"
    new_customer.customer_group = _first_leaf("Customer Group", "Individual")
    new_customer.customer_type = "Individual"
    new_customer.territory = _first_leaf("Territory", "Rest Of The World")
    new_customer.flags.ignore_shopify_update = True
    new_customer.insert(ignore_permissions=True)

    return new_customer.name


def scheduled_retrieve_shopify_orders():
    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    retrieve_shopify_orders(
        shopify_doc.api_key,
        shopify_doc.access_token,
        shopify_doc.shopify_url,
    )


@frappe.whitelist()
def test_scheduler_event():
    frappe.log_error("Scheduler event is working!", "Shopify Scheduler Test")
