import requests
import frappe

from shopify.utils import get_shopify_access


@frappe.whitelist()
def retrieve_shopify_customers(api_key, api_password, shopify_store_url):
    api_endpoint = f"{shopify_store_url}customers.json?limit=250"
    headers = {
        "X-Shopify-Access-Token": api_password,
        "Content-Type": "application/json",
    }

    while api_endpoint:
        try:
            response = requests.get(api_endpoint, headers=headers, timeout=30)
        except requests.RequestException:
            frappe.log_error(
                title="Shopify Customer Fetch Failed",
                message=frappe.get_traceback(),
            )
            break

        if response.status_code != 200:
            frappe.log_error(
                title="Shopify Customer Fetch Failed",
                message=f"Status: {response.status_code}\n{response.text}",
            )
            break

        customers_data = response.json().get("customers", [])
        if customers_data:
            create_customer(customers_data)
            frappe.logger().info(
                f"Shopify customers retrieved: {len(customers_data)}"
            )
        else:
            frappe.logger().info("No customers retrieved from Shopify.")

        api_endpoint = None
        link_header = response.headers.get("Link")
        if link_header:
            for part in link_header.split(","):
                if 'rel="next"' in part:
                    api_endpoint = part.split(";")[0].strip("<> ")
                    break

    frappe.logger().info("Shopify customer sync completed")


def _first_leaf(doctype, fallback):
    values = frappe.get_all(
        doctype, filters={"is_group": 0}, pluck="name", limit=1
    )
    return values[0] if values else fallback


def create_customer(shopify_customers):
    customer_group = _first_leaf("Customer Group", "Individual")
    territory = _first_leaf("Territory", "Rest Of The World")

    for shopify_customer in shopify_customers:
        shopify_customer_id = shopify_customer.get("id")
        if not shopify_customer_id:
            continue
        shopify_customer_id = str(shopify_customer_id)

        first_name = shopify_customer.get("first_name") or ""
        last_name = shopify_customer.get("last_name") or ""
        email = shopify_customer.get("email") or ""
        phone = shopify_customer.get("phone") or ""
        full_name = f"{first_name} {last_name}".strip()
        if not full_name:
            # Guest checkouts carry neither name nor email; identify them by id
            # instead of stacking identical "Shopify Customer" rows.
            full_name = email or ("Shopify Guest %s" % shopify_customer_id[-4:])

        existing_customer = frappe.db.get_value(
            "Customer",
            {"shopify_customer_id": shopify_customer_id},
            "name",
        )

        if existing_customer:
            customer = frappe.get_doc("Customer", existing_customer)
            customer.customer_name = full_name
            customer.email_id = email
            customer.mobile_no = phone
            customer.flags.ignore_shopify_update = True
            customer.save(ignore_permissions=True)
            continue

        customer = frappe.new_doc("Customer")
        customer.customer_name = full_name
        customer.email_id = email
        customer.shopify_customer_id = shopify_customer_id
        customer.mobile_no = phone
        customer.default_currency = "MYR"
        customer.default_price_list = "Standard Selling"
        customer.customer_group = customer_group
        customer.customer_type = "Individual"
        customer.territory = territory
        customer.flags.ignore_shopify_update = True
        customer.insert(ignore_permissions=True)

        frappe.logger().info(f"Customer {customer.name} created from Shopify")


def create_contact(shopify_customer):
    contact = frappe.new_doc("Contact")
    contact.first_name = shopify_customer.get("first_name") or "Shopify"
    contact.last_name = shopify_customer.get("last_name") or "Customer"
    contact.is_primary_contact = 1

    email = shopify_customer.get("email")
    phone = shopify_customer.get("phone")

    if email:
        contact.append("email_ids", {"email_id": email, "is_primary": 1})

    if phone:
        contact.append(
            "phone_nos", {"phone": phone, "is_primary_mobile_no": 1}
        )

    contact.insert(ignore_permissions=True)
    return contact


def on_submit():
    shopify_doc = get_shopify_access()
    if not shopify_doc:
        return
    retrieve_shopify_customers(
        shopify_doc.api_key,
        shopify_doc.access_token,
        shopify_doc.shopify_url,
    )
