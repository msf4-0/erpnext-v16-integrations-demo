#!/usr/bin/env bash
# Verify barcode_shrdc integration on the frontend site.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

echo "== list-apps =="
bench --site frontend list-apps

echo "== Client Script fixtures =="
bench --site frontend execute frappe.client.get_list --kwargs '{"doctype":"Client Script","fields":["name"]}'

echo "== Barcode Shrdc doctypes =="
bench --site frontend execute frappe.client.get_list --kwargs '{"doctype":"DocType","filters":{"module":"Barcode Shrdc"},"fields":["name"]}'

echo "== REST check: Barcode Printing =="
curl -s -c /tmp/c.txt -H "Host: frontend" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' http://localhost:8000/api/method/login > /dev/null
curl -s -b /tmp/c.txt -H "Host: frontend" -o /dev/null -w "HTTP %{http_code}\n" \
  "http://localhost:8000/api/resource/Barcode%20Printing?limit_page_length=1"
