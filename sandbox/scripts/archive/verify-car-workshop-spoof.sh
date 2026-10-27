#!/usr/bin/env bash
# Prove the read-only workshop summary is genuinely recomputed server-side, by
# spoofing them with a VALID (but wrong) value over REST. The earlier attempt
# used an invalid workshop name, which link-validation rejected with 417 before
# validate() even ran — a different (also-good) behaviour, but not proof of the
# recompute. Here we use a real second workshop so the write gets far enough.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
PORT="${PORT:-8000}"
cd /home/frappe/frappe-bench || exit 1

curl -s -c /tmp/sp.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "http://localhost:$PORT/api/method/login" > /dev/null

mk_ws () {
  curl -s -b /tmp/sp.txt -H "Host: $SITE" -H "Content-Type: application/json" \
    -X POST "http://localhost:$PORT/api/resource/Car%20Workshop" \
    -d "{\"doctype\":\"Car Workshop\",\"workshop_name\":\"$1\",\"status\":\"Active\"}"
}

mk_ws "Spoof Workshop A" > /tmp/sp-a.json
mk_ws "Spoof Workshop B" > /tmp/sp-b.json
A=$(env/bin/python -c "import json;print(json.load(open('/tmp/sp-a.json'))['data']['name'])")
B=$(env/bin/python -c "import json;print(json.load(open('/tmp/sp-b.json'))['data']['name'])")
echo "workshops: A=$A B=$B"

echo "== create a car whose row references A =="
curl -s -b /tmp/sp.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "http://localhost:$PORT/api/resource/Car" \
  -d "{\"doctype\":\"Car\",\"license_plate\":\"SPOOFWS-0001\",\"make\":\"X\",\"model\":\"Y\",\"status\":\"Active\",\"last_recorded_mileage\":1000,\"service_records\":[{\"service_type\":\"Oil Change\",\"service_date\":\"2026-08-01\",\"odometer\":1000,\"workshop\":\"$A\"}]}" \
  > /tmp/sp-car.json
CAR=$(env/bin/python -c "import json;print(json.load(open('/tmp/sp-car.json'))['data']['name'])")
env/bin/python -c "import json;d=json.load(open('/tmp/sp-car.json'))['data'];print('  created',d['name'],'last_workshop=',d['last_workshop'],'used=',d['workshops_used'])"

echo "== spoof with a VALID but WRONG workshop B and used=99 =="
curl -s -b /tmp/sp.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -o /dev/null -w "PUT HTTP %{http_code}\n" \
  -X PUT "http://localhost:$PORT/api/resource/Car/$CAR" \
  -d "{\"last_workshop\":\"$B\",\"workshops_used\":99}"

echo "== re-read (expect A and 1, i.e. recomputed) =="
curl -s -b /tmp/sp.txt -H "Host: $SITE" \
  "http://localhost:$PORT/api/resource/Car/$CAR?fields=%5B%22last_workshop%22%2C%22workshops_used%22%5D"
echo

echo "== cleanup =="
curl -s -b /tmp/sp.txt -H "Host: $SITE" -o /dev/null -w "del car HTTP %{http_code}\n" \
  -X DELETE "http://localhost:$PORT/api/resource/Car/$CAR"
curl -s -b /tmp/sp.txt -H "Host: $SITE" -o /dev/null -w "del A HTTP %{http_code}\n" \
  -X DELETE "http://localhost:$PORT/api/resource/Car%20Workshop/$A"
curl -s -b /tmp/sp.txt -H "Host: $SITE" -o /dev/null -w "del B HTTP %{http_code}\n" \
  -X DELETE "http://localhost:$PORT/api/resource/Car%20Workshop/$B"
