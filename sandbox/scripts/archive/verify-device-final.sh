#!/usr/bin/env bash
# Final consolidated verification of the robotics_lab / Device feature.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

echo "== list-apps =="
bench --site "$SITE" list-apps

echo
echo "== Device rows in DB (the demo device should remain) =="
bench --site "$SITE" execute robotics_lab._diag.cleanup.run 2>/dev/null || true

echo
echo "== site ping =="
curl -s -o /dev/null -w "ping: %{http_code}\n" -H "Host: $SITE" http://localhost:8000/api/method/ping

echo
echo "== authoritative clean source still staged? =="
ls /tmp/final-app/robotics_lab >/dev/null 2>&1 && echo "yes: /tmp/final-app/robotics_lab" || echo "MISSING"
find /tmp/final-app/robotics_lab -name device.json

echo
echo "== host-port check (8001) =="
GW_HEX=$(awk '$2=="00000000" {print $3; exit}' /proc/net/route)
GW=$(printf '%d.%d.%d.%d' 0x${GW_HEX:6:2} 0x${GW_HEX:4:2} 0x${GW_HEX:2:2} 0x${GW_HEX:0:2})
curl -s -o /dev/null -w "host:8001 ping -> %{http_code}\n" -H "Host: $SITE" \
  "http://$GW:8001/api/method/ping"
