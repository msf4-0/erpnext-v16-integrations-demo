#!/usr/bin/env bash
# ai-fix-shopify-sync.sh — configure the Shopify Access credential and prove the
# ERPNext <-> Shopify link is real, by importing the store's products as Items
# and its orders as Sales Orders.
#
# Proves "connected", rather than "installed":
#   * calls the Shopify Admin API through the app's own code paths
#   * lists the resulting Items (compare with the store's product page)
#   * lists the resulting Sales Orders (compare with the store's order list)
#
# Run inside the bench container:
#   bash /tmp/scripts/ai-fix-shopify-sync.sh <shpat_token> <store_host> <api_version>
# e.g.
#   bash /tmp/scripts/ai-fix-shopify-sync.sh shpat_xxx 4e1075.myshopify.com 2026-04
set -uo pipefail

TOKEN="${1:-}"
STORE="${2:-4e1075.myshopify.com}"
VERSION="${3:-2026-04}"
SITE="${SITE_NAME:-frontend}"
APP=/home/frappe/frappe-bench/apps/shopify/shopify

if [ -z "$TOKEN" ]; then
  echo "usage: $0 <shpat_token> [store_host] [api_version]"
  exit 2
fi
cd /home/frappe/frappe-bench || exit 1

say() { echo; echo "----- $* -----"; }

# ---------------------------------------------------------------------------
# 1. Shopify Access record
# ---------------------------------------------------------------------------
say "Shopify Access credential"
cat > "$APP/_aifix_access.py" <<'PYEOF'
import frappe

TOKEN = "__TOKEN__"
STORE = "__STORE__"
VERSION = "__VERSION__"


def run():
	name = frappe.db.get_value("Shopify Access", {}, "name")
	doc = frappe.get_doc("Shopify Access", name) if name else frappe.new_doc("Shopify Access")

	doc.link_name = "SHRDC"
	doc.app_type = "Custom"
	doc.shop_domain_url = "https://%s" % STORE
	doc.api_key = TOKEN
	doc.access_token = TOKEN
	doc.updated_version = VERSION
	doc.shopify_url = "https://%s/admin/api/%s/" % (STORE, VERSION)
	doc.flags.ignore_permissions = True
	doc.save()
	frappe.db.commit()
	frappe.clear_cache()
	print("MARK_ACCESS %s | %s | v%s" % (doc.name, doc.shop_domain_url, doc.updated_version))
	return doc.name
PYEOF

python3 - "$TOKEN" "$STORE" "$VERSION" <<'PYSUB'
import pathlib, sys
p = pathlib.Path("/home/frappe/frappe-bench/apps/shopify/shopify/_aifix_access.py")
t = p.read_text()
t = t.replace("__TOKEN__", sys.argv[1]).replace("__STORE__", sys.argv[2]).replace("__VERSION__", sys.argv[3])
p.write_text(t)
PYSUB

ACCESS=$(bench --site "$SITE" execute shopify._aifix_access.run 2>&1 | tee /tmp/aifix_access.log | grep -o 'MARK_ACCESS .*')
if [ -n "$ACCESS" ]; then
  echo "  $ACCESS"
else
  echo "  FAILED to create Shopify Access:"
  tail -20 /tmp/aifix_access.log
fi
rm -f "$APP/_aifix_access.py"

# ---------------------------------------------------------------------------
# 2. import products -> Items
# ---------------------------------------------------------------------------
say "import Shopify products as Items"
cat > "$APP/_aifix_sync.py" <<'PYEOF'
import frappe

from shopify.retrieve_order import retrieve_shopify_orders
from shopify.retrieve_product import retrieve_shopify_product
from shopify.utils import get_shopify_access


def products():
	doc = get_shopify_access()
	if not doc:
		print("MARK_ERR no Shopify Access configured")
		return 0
	retrieve_shopify_product(doc.api_key, doc.access_token, doc.shopify_url)
	frappe.db.commit()
	rows = frappe.get_all(
		"Item",
		fields=["name", "item_name", "shopify_product_id"],
		order_by="creation asc",
		limit_page_length=0,
	)
	print("MARK_COUNT_ITEMS %d" % len(rows))
	for row in rows:
		print("MARK_ITEM %s | %s | shopify_id=%s" % (row.name, row.item_name, row.shopify_product_id))
	return len(rows)


def orders():
	doc = get_shopify_access()
	if not doc:
		print("MARK_ERR no Shopify Access configured")
		return 0
	retrieve_shopify_orders(doc.api_key, doc.access_token, doc.shopify_url)
	frappe.db.commit()
	rows = frappe.get_all(
		"Sales Order",
		fields=["name", "shopify_order_id", "customer", "grand_total", "transaction_date"],
		order_by="creation asc",
		limit_page_length=0,
	)
	print("MARK_COUNT_SO %d" % len(rows))
	for row in rows:
		print(
			"MARK_SO %s | erpnext=%s | customer=%s | total=%s"
			% (row.shopify_order_id, row.name, row.customer, row.grand_total)
		)
	return len(rows)
PYEOF

bench --site "$SITE" execute shopify._aifix_sync.products 2>&1 | tee /tmp/aifix_prod.log | grep -E '^MARK_' | head -40
echo "  item sync errors (if any):"
grep -iE 'error|traceback|exception' /tmp/aifix_prod.log | head -5

# ---------------------------------------------------------------------------
# 3. import orders -> Sales Orders
# ---------------------------------------------------------------------------
say "import Shopify orders as Sales Orders"
bench --site "$SITE" execute shopify._aifix_sync.orders 2>&1 | tee /tmp/aifix_ord.log | grep -E '^MARK_' | head -40
echo "  order sync errors (if any):"
grep -iE 'error|traceback|exception' /tmp/aifix_ord.log | head -8

rm -f "$APP/_aifix_sync.py"
find "$APP" -name '_aifix_*' -delete 2>/dev/null || true

say "summary"
bench --site "$SITE" --cmd "list-apps" 2>/dev/null || bench --site "$SITE" list-apps
