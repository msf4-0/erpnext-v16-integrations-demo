#!/usr/bin/env bash
# REST + client-script verification for the Car doctype on v16.
# Authenticated requests only (an unauth request fails regardless of whether
# the feature works). The app doctype's .js is delivered INLINE via getdoctype's
# __js field on v16 — /assets/<app>/js/<doctype>.js 404s and that is expected.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
PORT="${PORT:-8000}"
cd /home/frappe/frappe-bench || exit 1

echo "== login =="
curl -s -c /tmp/car-cookies.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "http://localhost:$PORT/api/method/login"
echo

echo "== list Cars =="
curl -s -b /tmp/car-cookies.txt -H "Host: $SITE" -o /tmp/car-list.json -w "HTTP %{http_code}\n" \
  "http://localhost:$PORT/api/resource/Car?limit_page_length=5&fields=%5B%22name%22%2C%22license_plate%22%2C%22service_status%22%5D"
cat /tmp/car-list.json | head -c 600
echo

echo "== create a Car over REST (with a service row) =="
curl -s -b /tmp/car-cookies.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -o /tmp/car-create.json -w "HTTP %{http_code}\n" \
  -X POST "http://localhost:$PORT/api/resource/Car" \
  -d '{"doctype":"Car","license_plate":"REST-0001","make":"Honda","model":"Civic","status":"Active","last_recorded_mileage":15000,"oil_change_interval_months":6,"oil_change_interval_km":5000,"service_records":[{"service_type":"Oil Change","service_date":"2026-08-01","odometer":14000,"cost":200}]}'
env/bin/python - <<'PYEOF'
import json
d = json.load(open("/tmp/car-create.json")).get("data", {})
print("name:", d.get("name"))
for f in ("last_oil_change_date", "last_oil_change_mileage", "next_oil_change_due_date",
          "next_oil_change_due_mileage", "last_maintenance_date", "service_records_count",
          "total_maintenance_cost", "service_status"):
    print(f"  {f}: {d.get(f)}")
open("/tmp/car-created-name.txt", "w").write(d.get("name") or "")
PYEOF

NAME=$(cat /tmp/car-created-name.txt)
echo "== GET the created Car =="
curl -s -b /tmp/car-cookies.txt -H "Host: $SITE" -o /tmp/car-get.json -w "HTTP %{http_code}\n" \
  "http://localhost:$PORT/api/resource/Car/$NAME"
env/bin/python - <<'PYEOF'
import json
d = json.load(open("/tmp/car-get.json")).get("data", {})
print("service_records rows:", len(d.get("service_records") or []))
print("read_only last_oil_change_date:", d.get("last_oil_change_date"))
PYEOF

echo "== spoof read-only over REST (PUT) then re-read =="
curl -s -b /tmp/car-cookies.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -o /tmp/car-update.json -w "HTTP %{http_code}\n" \
  -X PUT "http://localhost:$PORT/api/resource/Car/$NAME" \
  -d '{"last_oil_change_mileage":999999,"service_records_count":999}'
curl -s -b /tmp/car-cookies.txt -H "Host: $SITE" \
  "http://localhost:$PORT/api/resource/Car/$NAME?fields=%5B%22last_oil_change_mileage%22%2C%22service_records_count%22%5D"
echo

echo "== getdoctype: served __js contains the handlers =="
curl -s -b /tmp/car-cookies.txt -H "Host: $SITE" -o /tmp/car-meta.json -w "HTTP %{http_code}\n" \
  "http://localhost:$PORT/api/method/frappe.client.get_js?doctype=Car"
env/bin/python - <<'PYEOF'
import json
raw = open("/tmp/car-meta.json").read()
try:
    js = json.loads(raw).get("message") or ""
except Exception:
    js = raw
checks = ["compute_service_summary", "last_oil_change_date", "service_status",
          "Car Service Record", "service_records_remove"]
print("js length:", len(js))
for c in checks:
    print(f"  contains {c!r}: {c in js}")
PYEOF

echo "== cleanup REST test record =="
curl -s -b /tmp/car-cookies.txt -H "Host: $SITE" -X DELETE -o /dev/null -w "DELETE HTTP %{http_code}\n" \
  "http://localhost:$PORT/api/resource/Car/$NAME"

echo "== site health =="
curl -s -o /dev/null -w "ping HTTP %{http_code}\n" -H "Host: $SITE" "http://localhost:$PORT/api/method/ping"
echo "== regression: core doctypes still served =="
curl -s -b /tmp/car-cookies.txt -H "Host: $SITE" -o /dev/null -w "Company HTTP %{http_code}\n" \
  "http://localhost:$PORT/api/resource/Company?limit_page_length=1"
curl -s -b /tmp/car-cookies.txt -H "Host: $SITE" -o /dev/null -w "Item HTTP %{http_code}\n" \
  "http://localhost:$PORT/api/resource/Item?limit_page_length=1"
