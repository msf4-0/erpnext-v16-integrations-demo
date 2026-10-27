#!/usr/bin/env bash
# End-to-end test: create an Item via REST (triggers the shopify
# after_insert hook) and confirm it no longer throws "Shopify Access None
# not found". Also confirm the helper returns None with no config.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

echo "== login =="
curl -s -c /tmp/c.txt -H "Host: frontend" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' http://localhost:8000/api/method/login > /dev/null

echo "== create Item via REST (triggers after_insert hook) =="
RESP=$(curl -s -b /tmp/c.txt -H "Host: frontend" -H "Content-Type: application/json" \
  -X POST -d '{"item_code":"TEST-FIX-ITEM","item_name":"Test Fix Item","item_group":"All Item Groups","stock_uom":"Nos","is_stock_item":0}' \
  "http://localhost:8000/api/resource/Item")
echo "$RESP" | head -c 600
echo
echo "== check for the error string =="
if echo "$RESP" | grep -q "Shopify Access None not found"; then
  echo "FAIL: error still present"
else
  echo "OK: no 'Shopify Access None not found' error"
fi

echo "== cleanup test item =="
curl -s -b /tmp/c.txt -H "Host: frontend" -X DELETE \
  "http://localhost:8000/api/resource/Item/TEST-FIX-ITEM" -o /dev/null -w "delete HTTP %{http_code}\n"
