#!/usr/bin/env python3
"""Configure Shopify Access and prove the ERPNext <-> Shopify link is real.

Run with the bench venv python (NOT `bench execute`, which mangles dotted module
paths on this install):

    env/bin/python /tmp/shopify_sync.py <shpat_token> <store> <api_version> \
        [<client_id> <client_secret>]

The last two arguments are the Dev Dashboard app credentials. They are written
into site_config.json as `shopify_client_id` / `shopify_client_secret` so
`shopify.auth` can mint a fresh 24 h Admin API token on demand - the static
`shpat_...` token in argument 1 expires daily on this store.
"""
import json
import os
import sys

os.chdir("/home/frappe/frappe-bench/sites")   # so frappe resolves site paths correctly
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe

SITE = "frontend"


def write_site_config(key, value):
    """Persist into {site}/site_config.json (durable across container rebuilds
    because `sites/` is the named volume) and into the live frappe.conf."""
    path = os.path.join(SITE, "site_config.json")
    try:
        with open(path) as handle:
            cfg = json.load(handle)
    except Exception:
        cfg = {}
    cfg[key] = value
    with open(path, "w") as handle:
        json.dump(cfg, handle, indent=2, sort_keys=True)
    try:
        frappe.conf[key] = value
    except Exception:
        pass
    return path


def main() -> int:
    argv = sys.argv[1:]
    if len(argv) < 3:
        print("usage: shopify_sync.py <token> <store> <api_version> [client_id] [client_secret]")
        return 2
    token, store, version = argv[0], argv[1], argv[2]
    client_id = argv[3] if len(argv) > 3 else ""
    client_secret = argv[4] if len(argv) > 4 else ""

    frappe.init(site=SITE, sites_path=".")
    frappe.connect()
    frappe.set_user("Administrator")
    print("MARK_SITE %s path=%s" % (frappe.local.site, frappe.local.site_path))

    # ---- durable token credentials (must happen before any Shopify call) ----
    if client_id and client_secret:
        write_site_config("shopify_client_id", client_id)
        write_site_config("shopify_client_secret", client_secret)
        write_site_config("shopify_store", store)
        write_site_config("shopify_api_version", version)
        frappe.db.commit()
        print("MARK_CREDS site_config shopify_client_id=%s...%s store=%s version=%s"
              % (client_id[:6], client_id[-4:], store, version))
    else:
        print("MARK_CREDS none - falling back to the static token only")

    name = frappe.db.get_value("Shopify Access", {}, "name")
    doc = frappe.get_doc("Shopify Access", name) if name else frappe.new_doc("Shopify Access")
    doc.link_name = "SHRDC"
    doc.app_type = "Custom"
    doc.shop_domain_url = "https://%s" % store
    doc.api_key = token
    doc.access_token = token
    doc.updated_version = version
    doc.shopify_url = "https://%s/admin/api/%s/" % (store, version)
    # These four are REQUIRED by the doctype; a site without the setup wizard
    # has no Company/Bank Account at all, so bootstrap_masters.py must run first.
    doc.shopify_account = "Main"
    doc.secret_key = token
    doc.company = frappe.db.get_value("Company", {}, "name")
    # bank_account links to ACCOUNT (the GL account), not to Bank Account
    doc.bank_account = frappe.db.get_value("Bank Account", {}, "account")
    doc.flags.ignore_permissions = True
    doc.save()
    frappe.db.commit()
    print("MARK_ACCESS %s | %s | %s" % (doc.name, doc.shop_domain_url, doc.shopify_url))

    # ---- prove the minted token works before trusting the sync ---------------
    if client_id and client_secret:
        from shopify.auth import get_access_token, token_status

        minted = get_access_token(doc, force=True)
        if minted:
            print("MARK_MINT ok prefix=%s len=%d" % (minted[:12], len(minted)))
        else:
            print("MARK_MINT_ERR minting failed - see the Error Log")
        print("MARK_TOKEN_STATUS %s" % json.dumps(token_status(), sort_keys=True))

        import requests

        try:
            probe = requests.get(
                "https://%s/admin/api/%s/shop.json" % (store, version),
                headers={"X-Shopify-Access-Token": minted or token},
                timeout=30,
            )
            if probe.status_code == 200:
                shop = probe.json().get("shop", {})
                print("MARK_SHOP_OK %s | %s | %s"
                      % (shop.get("name"), shop.get("myshopify_domain"), shop.get("currency")))
            else:
                print("MARK_SHOP_ERR HTTP %s %s" % (probe.status_code, (probe.text or "")[:300]))
        except Exception as exc:
            print("MARK_SHOP_ERR %s: %s" % (type(exc).__name__, exc))

    from shopify.retrieve_order import retrieve_shopify_orders
    from shopify.retrieve_product import retrieve_shopify_product


    try:
        retrieve_shopify_product(doc.api_key, doc.access_token, doc.shopify_url)
        frappe.db.commit()
        print("MARK_PRODUCT_SYNC ok")
    except Exception as exc:
        print("MARK_PRODUCT_ERR %s: %s" % (type(exc).__name__, exc))

    items = frappe.get_all("Item", fields=["name", "item_name", "shopify_product_id"], limit_page_length=0)
    print("MARK_COUNT_ITEMS %d" % len(items))
    for row in items:
        print("MARK_ITEM %s | %s | shopify_id=%s" % (row.name, row.item_name, row.shopify_product_id))

    try:
        retrieve_shopify_orders(doc.api_key, doc.access_token, doc.shopify_url)
        frappe.db.commit()
        print("MARK_ORDER_SYNC ok")
    except Exception as exc:
        print("MARK_ORDER_ERR %s: %s" % (type(exc).__name__, exc))

    orders = frappe.get_all(
        "Sales Order",
        fields=["name", "shopify_order_id", "customer", "grand_total", "transaction_date"],
        limit_page_length=0,
    )
    print("MARK_COUNT_SO %d" % len(orders))
    for row in orders:
        print("MARK_SO %s | shopify=%s | %s | %s | %s"
              % (row.name, row.shopify_order_id, row.customer, row.grand_total, row.transaction_date))

    frappe.destroy()
    return 0


if __name__ == "__main__":
    sys.exit(main())