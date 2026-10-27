"""Import only the N most recent Shopify orders into ERPNext.

`shopify.retrieve_order.retrieve_shopify_orders()` walks EVERY order (250 per
page, all pages) with no date filter, so running it on this store would create
Sales Orders for the whole order history. This imports just the newest few so a
fresh test order can be verified end to end.

Idempotent: create_sales_order() returns early when a Sales Order with that
shopify_order_id already exists.
"""
import frappe
import requests

SHOP = "4e1075.myshopify.com"


def run(limit=2):
    from shopify.retrieve_order import create_sales_order

    rows = frappe.get_all(
        "Shopify Access",
        fields=["api_key", "access_token", "shopify_url"],
        limit=1,
    )
    if not rows:
        print("MARK_ERR no Shopify Access record")
        return

    base = (rows[0].shopify_url or "").rstrip("/")
    if not base:
        print("MARK_ERR Shopify Access has no shopify_url")
        return

    url = "%s/orders.json?status=any&limit=%d" % (base, int(limit))
    resp = requests.get(
        url,
        headers={
            "X-Shopify-Access-Token": rows[0].access_token,
            "Content-Type": "application/json",
        },
        timeout=60,
    )
    if resp.status_code != 200:
        print("MARK_ERR fetch %s: %s" % (resp.status_code, resp.text[:200]))
        return

    orders = resp.json().get("orders", [])
    print("MARK_FETCH %d orders" % len(orders))

    for order in orders:
        try:
            create_sales_order(order)
            print("MARK_IMPORT %s | id=%s" % (order.get("name"), order.get("id")))
        except Exception as exc:  # noqa: BLE001 - report and continue
            print(
                "MARK_FAIL %s | id=%s | %s"
                % (order.get("name"), order.get("id"), str(exc)[:200])
            )

    frappe.db.commit()
