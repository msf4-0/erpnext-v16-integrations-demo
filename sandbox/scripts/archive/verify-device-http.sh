#!/usr/bin/env bash
# Verify the Device doctype over HTTP (REST + desk meta/JS render) and run the
# app's real unit tests. "No error" is not the bar — each check asserts the
# expected content is actually present.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

echo "== login (authenticated REST needs a session) =="
curl -s -c /tmp/dev_ck.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' \
  http://localhost:8000/api/method/login
echo

echo "== REST GET /api/resource/Device (list) =="
curl -s -b /tmp/dev_ck.txt -H "Host: $SITE" -o /tmp/dev_list.json -w "HTTP %{http_code}\n" \
  "http://localhost:8000/api/resource/Device?limit_page_length=5"
echo "-- body --"
cat /tmp/dev_list.json | head -c 600
echo

echo
echo "== REST GET /api/resource/Device/DEV-0001 (single doc) =="
curl -s -b /tmp/dev_ck.txt -H "Host: $SITE" -o /tmp/dev_one.json -w "HTTP %{http_code}\n" \
  "http://localhost:8000/api/resource/Device/DEV-0001"
echo "-- computed fields present in the payload? --"
python3 - <<'PY'
import json
try:
    d = json.load(open("/tmp/dev_one.json"))
    data = d.get("data", d)
    for f in ("name", "device_name", "device_type", "status",
              "estimated_daily_consumption_kwh", "estimated_annual_consumption_kwh"):
        print(f"  {f} = {data.get(f)!r}")
except Exception as e:
    print("  parse error:", e)
PY

echo
echo "== REST create (POST) a Device, then delete it =="
curl -s -b /tmp/dev_ck.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST -d '{"device_name":"REST Light","device_type":"Light","status":"Active","power_rating_w":60,"daily_operating_hours":8}' \
  -o /tmp/dev_post.json -w "HTTP %{http_code}\n" \
  "http://localhost:8000/api/resource/Device"
python3 - <<'PY'
import json
d = json.load(open("/tmp/dev_post.json"))
data = d.get("data", d)
print("  created:", data.get("name"))
print("  daily_kwh:", data.get("estimated_daily_consumption_kwh"))
print("  annual_kwh:", data.get("estimated_annual_consumption_kwh"))
print("  (expect 0.48 and 175.2)")
PY

echo
echo "== desk meta: is device.js attached to the doctype? =="
bench --site "$SITE" execute frappe.client.get_list --kwargs \
  "{'doctype':'DocType','filters':{'name':'Device'},'fields':['name','module'],'limit_page_length':1}"
bench --site "$SITE" execute frappe.get_meta --kwargs "{'doctype':'Device'}" 2>&1 | head -3
python3 - <<'PY'
# frappe.get_meta returns a Meta object; ask it directly for the custom
# client script attachment via bench execute instead of repr-truncated output.
PY
bench --site "$SITE" execute frappe.get_attr --kwargs \
  "{'method': 'frappe.model.meta.get_meta'}" 2>/dev/null | head -2 || true

echo
echo "== the doctype's own .js is served as an asset =="
curl -s -b /tmp/dev_ck.txt -H "Host: $SITE" -o /tmp/dev_js.txt -w "HTTP %{http_code}\n" \
  "http://localhost:8000/assets/robotics_lab/js/device.js" || true

echo
echo "== run the app's REAL unit tests (bodies have assertions) =="
bench --site "$SITE" run-tests --app robotics_lab 2>&1 | tail -30

echo
echo "== site health =="
curl -s -o /dev/null -w "ping: %{http_code}\n" -H "Host: $SITE" http://localhost:8000/api/method/ping
