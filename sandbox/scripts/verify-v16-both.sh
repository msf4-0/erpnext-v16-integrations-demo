#!/usr/bin/env bash
# Verify e_invoice_erp + shopify on the running site.
set -uo pipefail
SITE=frontend
cd /home/frappe/frappe-bench || exit 1

echo "-- list-apps --"
bench --site "$SITE" list-apps

echo "-- doctypes (E Invoice Erp) --"
bench --site "$SITE" execute frappe.client.get_list --kwargs "{\"doctype\":\"DocType\",\"filters\":{\"module\":\"E Invoice Erp\"},\"fields\":[\"name\"],\"limit_page_length\":50}"

echo "-- doctypes (Shopify) --"
bench --site "$SITE" execute frappe.client.get_list --kwargs "{\"doctype\":\"DocType\",\"filters\":{\"module\":\"Shopify\"},\"fields\":[\"name\"],\"limit_page_length\":50}"

echo "-- custom fields (shopify) --"
bench --site "$SITE" execute frappe.client.get_list --kwargs "{\"doctype\":\"Custom Field\",\"filters\":[[\"fieldname\",\"in\",[\"shopify_product_id\",\"shopify_order_id\",\"shopify_customer_id\"]]],\"fields\":[\"dt\",\"fieldname\"],\"limit_page_length\":50}"

echo "-- REST: login --"
curl -s -c /tmp/vc.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' http://localhost:8000/api/method/login > /dev/null
for DT in "API Credentials" "Shopify Access" "Shopify Link"; do
  ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$DT")
  CODE=$(curl -s -b /tmp/vc.txt -H "Host: $SITE" -o /dev/null -w "%{http_code}" \
    "http://localhost:8000/api/resource/$ENC?limit_page_length=1")
  echo "REST $DT: $CODE"
done

echo "-- site ping --"
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: $SITE" http://localhost:8000/api/method/ping
