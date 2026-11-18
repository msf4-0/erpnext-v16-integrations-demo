#!/usr/bin/env bash
# Verify the HOST-published port (8001) really serves the site, from inside
# the bench container: the compose network's default gateway is the Docker
# host, so curling http://<gateway>:8001 reaches the published port exactly
# as an external client would (with the Host header the site expects).
set -uo pipefail

# The `ip` tool is absent from this image; derive the gateway from /proc/net/route
# (default route has Destination 00000000) and convert the little-endian hex.
GW_HEX=$(awk '$2=="00000000" {print $3; exit}' /proc/net/route)
GW=$(printf '%d.%d.%d.%d' \
  0x${GW_HEX:6:2} 0x${GW_HEX:4:2} 0x${GW_HEX:2:2} 0x${GW_HEX:0:2})
echo "docker host gateway: $GW"

echo "== HTTP via host-published port 8001 (ping) =="
curl -s -o /dev/null -w "HTTP %{http_code}\n" -H "Host: frontend" \
  "http://$GW:8001/api/method/ping"

echo "== HTTP via host-published port 8001 (Shopify Access REST, no auth => expect 403/401, not connection failure) =="
curl -s -o /dev/null -w "HTTP %{http_code}\n" -H "Host: frontend" \
  "http://$GW:8001/api/resource/Shopify%20Access?limit_page_length=1"

echo "== sanity: same two checks on the container-internal port 8000 =="
curl -s -o /dev/null -w "internal ping HTTP %{http_code}\n" -H "Host: frontend" \
  "http://localhost:8000/api/method/ping"
