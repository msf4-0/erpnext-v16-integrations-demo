#!/usr/bin/env python3
"""Inspect / refresh the Shopify Admin API token the ERPNext side uses.

Run inside the bench container:

    cd /home/frappe/frappe-bench && SITE_NAME=frontend ./env/bin/python \
        /tmp/scripts/shopify-token.py [status|refresh|verify]

  status   cached token present? which store? is minting configured?
  refresh  force a client_credentials mint now (this is what the ERPNext side
           calls by itself once a day, so this is only for forcing it)
  verify   refresh + prove the token with GET /admin/api/<v>/shop.json

Printed as MARK_ lines so the host wrapper can read it.
"""
import json
import os
import sys

import frappe

SITE = os.environ.get("SITE_NAME", "frontend")
os.chdir("/home/frappe/frappe-bench/sites")
frappe.init(site=SITE, sites_path=".")
frappe.connect()
frappe.set_user("Administrator")

action = (sys.argv[1] if len(sys.argv) > 1 else "status").lower()

# `configure` writes the Dev Dashboard app credentials into site_config.json so
# shopify.auth can mint its own 24h tokens without a rebuild:
#   SHOPIFY_CLIENT_ID=... SHOPIFY_CLIENT_SECRET=... shopify-token.py configure
if action == "configure":
    client_id = os.environ.get("SHOPIFY_CLIENT_ID")
    client_secret = os.environ.get("SHOPIFY_CLIENT_SECRET")
    if not (client_id and client_secret):
        print("MARK_CONFIGURE FAIL SHOPIFY_CLIENT_ID / SHOPIFY_CLIENT_SECRET not in the environment")
        sys.exit(2)
    import json

    path = os.path.join(SITE, "site_config.json")
    with open(path) as handle:
        cfg = json.load(handle)
    cfg["shopify_client_id"] = client_id
    cfg["shopify_client_secret"] = client_secret
    cfg.setdefault("shopify_store", os.environ.get("SHOPIFY_STORE", "4e1075.myshopify.com"))
    cfg.setdefault("shopify_api_version", os.environ.get("SHOPIFY_API_VERSION", "2026-04"))
    with open(path, "w") as handle:
        json.dump(cfg, handle, indent=2, sort_keys=True)
    print(
        "MARK_CONFIGURE PASS site_config shopify_client_id=%s...%s store=%s"
        % (client_id[:6], client_id[-4:], cfg["shopify_store"])
    )

from shopify.auth import api_version, get_access_token, store_host, token_status
from shopify.utils import get_shopify_access

doc = get_shopify_access()

if action in ("refresh", "verify"):
    token = get_access_token(doc, force=True)
    if not token:
        print("MARK_REFRESH FAIL no token (see Error Log)")
        sys.exit(1)
    print("MARK_REFRESH PASS prefix=%s len=%d" % (token[:12], len(token)))

if action == "verify":
    import requests

    token = get_access_token(doc)
    url = "https://%s/admin/api/%s/shop.json" % (store_host(doc), api_version(doc))
    response = requests.get(url, headers={"X-Shopify-Access-Token": token}, timeout=30)
    if response.status_code == 200:
        shop = response.json().get("shop", {})
        print(
            "MARK_SHOP PASS %s | %s | %s"
            % (shop.get("name"), shop.get("myshopify_domain"), shop.get("currency"))
        )
    else:
        print("MARK_SHOP FAIL HTTP %s %s" % (response.status_code, (response.text or "")[:200]))

print("MARK_STATUS " + json.dumps(token_status(), sort_keys=True))
frappe.db.commit()
frappe.destroy()
