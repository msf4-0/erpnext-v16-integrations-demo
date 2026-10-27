"""Prove the Shopify order-sync path works two ways.

1. inline  - call the scheduler hook directly, so the created_at cutoff is
             exercised in-process (expect zero orders fetched).
2. queued  - enqueue the same method the way Frappe's scheduler does, so we can
             confirm `bench worker` picks it up and runs it.
"""
import frappe


def run():
    from shopify.retrieve_order import scheduled_retrieve_shopify_orders

    try:
        scheduled_retrieve_shopify_orders()
        print("MARK_INLINE ok")
    except Exception as exc:  # noqa: BLE001
        print("MARK_INLINE_ERR %s" % str(exc)[:300])

    frappe.enqueue(
        "shopify.retrieve_order.scheduled_retrieve_shopify_orders",
        queue="default",
        timeout=900,
    )
    frappe.db.commit()
    print("MARK_ENQUEUED")
