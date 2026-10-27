#!/usr/bin/env bash
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

echo "== list-apps =="
bench --site frontend list-apps

echo "== Barcode Shrdc doctypes =="
bench --site frontend execute frappe.client.get_list --kwargs '{"doctype":"DocType","filters":{"module":"Barcode Shrdc"},"fields":["name"]}'

echo "== Shopify doctypes =="
bench --site frontend execute frappe.client.get_list --kwargs '{"doctype":"DocType","filters":{"module":"Shopify"},"fields":["name"]}'

echo "== Barcode Custom Script fixtures =="
bench --site frontend execute frappe.client.get_list --kwargs '{"doctype":"Custom Script","fields":["name"]}'

echo "== Shopify custom fields =="
bench --site frontend execute frappe.client.get_list --kwargs '{"doctype":"Custom Field","filters":{"fieldname":["in",["shopify_product_id","shopify_order_id","shopify_customer_id"]]},"fields":["name","dt","fieldname"]}'

echo "== REST: login =="
curl -s -c /tmp/c.txt -H "Host: frontend" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' http://localhost:8000/api/method/login > /dev/null

echo "== REST: Barcode Printing =="
curl -s -b /tmp/c.txt -H "Host: frontend" -o /dev/null -w "HTTP %{http_code}\n" \
  "http://localhost:8000/api/resource/Barcode%20Printing?limit_page_length=1"

echo "== REST: Shopify Access =="
curl -s -b /tmp/c.txt -H "Host: frontend" -o /dev/null -w "HTTP %{http_code}\n" \
  "http://localhost:8000/api/resource/Shopify%20Access?limit_page_length=1"

echo "== REST: ping =="
curl -s -o /dev/null -w "HTTP %{http_code}\n" -H "Host: frontend" \
  "http://localhost:8000/api/method/ping"
