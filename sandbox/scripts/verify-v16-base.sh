#!/usr/bin/env bash
# Verify a bare ERPNext v16 base (no custom apps) on site "frontend".
# Runs INSIDE the bench container, so it exercises the container-internal
# port 8000. Host-port reachability is checked separately from the host.
set -uo pipefail
SITE=frontend
cd /home/frappe/frappe-bench || exit 1

echo "-- bench version --"
bench version

echo "-- list-apps --"
bench --site "$SITE" list-apps

echo "-- site ping (internal :8000) --"
curl -s -o /dev/null -w "ping: %{http_code}\n" -H "Host: $SITE" \
  http://localhost:8000/api/method/ping

echo "-- REST: login --"
LOGIN=$(curl -s -c /tmp/vb16.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' \
  http://localhost:8000/api/method/login)
echo "$LOGIN"

echo "-- REST: authenticated GET /api/resource/Company --"
CODE=$(curl -s -b /tmp/vb16.txt -H "Host: $SITE" -o /tmp/vb16_out.json -w "%{http_code}" \
  "http://localhost:8000/api/resource/Company?limit_page_length=1")
echo "REST Company: $CODE"

echo "-- REST: authenticated GET /api/resource/Item --"
CODE=$(curl -s -b /tmp/vb16.txt -H "Host: $SITE" -o /dev/null -w "%{http_code}" \
  "http://localhost:8000/api/resource/Item?limit_page_length=1")
echo "REST Item: $CODE"

echo "-- installed apps in DB --"
# NOTE: 'branch' is NOT a permitted query field on Installed Application in
# v16 (frappe DataError: "Field not permitted in query: branch"). Query only
# app_name + app_version here; branch comes from `bench version` instead.
bench --site "$SITE" execute frappe.client.get_list --kwargs \
  "{\"doctype\":\"Installed Application\",\"fields\":[\"app_name\",\"app_version\"],\"limit_page_length\":50}"
