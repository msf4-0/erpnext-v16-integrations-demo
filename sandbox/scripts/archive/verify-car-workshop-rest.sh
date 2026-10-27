#!/usr/bin/env bash
# REST + served-JS verification for the Car Workshop linkage on v16.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
PORT="${PORT:-8000}"
cd /home/frappe/frappe-bench || exit 1

curl -s -c /tmp/ws.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "http://localhost:$PORT/api/method/login" > /dev/null

echo "== GET /api/resource/Car Workshop =="
curl -s -b /tmp/ws.txt -H "Host: $SITE" -o /tmp/ws-list.json -w "HTTP %{http_code}\n" \
  "http://localhost:$PORT/api/resource/Car%20Workshop?limit_page_length=5"

echo "== POST a workshop =="
curl -s -b /tmp/ws.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -o /tmp/ws-create.json -w "HTTP %{http_code}\n" \
  -X POST "http://localhost:$PORT/api/resource/Car%20Workshop" \
  -d '{"doctype":"Car Workshop","workshop_name":"REST Workshop Sdn Bhd","status":"Active","phone":"+60312345678","hourly_rate":120}'
env/bin/python - <<'PYEOF'
import json
d = json.load(open("/tmp/ws-create.json")).get("data", {})
print("  name:", d.get("name"), "| phone:", d.get("phone"), "| rate:", d.get("hourly_rate"))
open("/tmp/ws-name.txt", "w").write(d.get("name") or "")
PYEOF
WSNAME=$(cat /tmp/ws-name.txt)

echo "== POST a Car referencing that workshop =="
curl -s -b /tmp/ws.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -o /tmp/car-create.json -w "HTTP %{http_code}\n" \
  -X POST "http://localhost:$PORT/api/resource/Car" \
  -d "{\"doctype\":\"Car\",\"license_plate\":\"RESTWS-0001\",\"make\":\"Honda\",\"model\":\"City\",\"status\":\"Active\",\"last_recorded_mileage\":9000,\"service_records\":[{\"service_type\":\"Oil Change\",\"service_date\":\"2026-08-01\",\"odometer\":8000,\"workshop\":\"$WSNAME\",\"cost\":180}]}"
env/bin/python - <<'PYEOF'
import json
d = json.load(open("/tmp/car-create.json")).get("data", {})
print("  car:", d.get("name"))
print("  last_workshop:", d.get("last_workshop"))
print("  workshops_used:", d.get("workshops_used"))
row = (d.get("service_records") or [{}])[0]
print("  row.workshop:", row.get("workshop"), "| row.workshop_phone:", row.get("workshop_phone"))
open("/tmp/carws-name.txt", "w").write(d.get("name") or "")
PYEOF
CARNAME=$(cat /tmp/carws-name.txt)

echo "== spoof last_workshop / workshops_used over REST (must recompute) =="
curl -s -b /tmp/ws.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -o /dev/null -w "PUT HTTP %{http_code}\n" \
  -X PUT "http://localhost:$PORT/api/resource/Car/$CARNAME" \
  -d '{"last_workshop":"NOPE-9999","workshops_used":99}'
curl -s -b /tmp/ws.txt -H "Host: $SITE" \
  "http://localhost:$PORT/api/resource/Car/$CARNAME?fields=%5B%22last_workshop%22%2C%22workshops_used%22%5D"
echo

echo "== delete the referencing car is blocked? (reverse link protection) =="
curl -s -b /tmp/ws.txt -H "Host: $SITE" -o /dev/null -w "DELETE workshop while referenced: HTTP %{http_code}\n" \
  -X DELETE "http://localhost:$PORT/api/resource/Car%20Workshop/$WSNAME"

echo "== cleanup =="
curl -s -b /tmp/ws.txt -H "Host: $SITE" -o /dev/null -w "delete car HTTP %{http_code}\n" \
  -X DELETE "http://localhost:$PORT/api/resource/Car/$CARNAME"
curl -s -b /tmp/ws.txt -H "Host: $SITE" -o /dev/null -w "delete workshop HTTP %{http_code}\n" \
  -X DELETE "http://localhost:$PORT/api/resource/Car%20Workshop/$WSNAME"

echo "== getdoctype Car: __js + field metadata =="
curl -s -b /tmp/ws.txt -H "Host: $SITE" \
  "http://localhost:$PORT/api/method/frappe.desk.form.load.getdoctype?doctype=Car" \
  -o /tmp/car-gd2.json -w "HTTP %{http_code}\n"
env/bin/python - <<'PYEOF'
import json
m = json.load(open("/tmp/car-gd2.json"))["docs"][0]
js = m.get("__js") or ""
for needle in ("distinct_workshop_names", "frappe.db", "Inactive", "frappe.confirm"):
    print(f"  __js contains {needle!r}: {needle in js}")
fields = {f["fieldname"]: f for f in m.get("fields", [])}
for fn in ("last_workshop", "workshops_used"):
    f = fields.get(fn)
    print(f"  {fn}: fieldtype={f and f.get('fieldtype')} read_only={f and f.get('read_only')} options={f and f.get('options')}")
PYEOF

echo "== child doctype metadata =="
curl -s -b /tmp/ws.txt -H "Host: $SITE" \
  "http://localhost:$PORT/api/method/frappe.desk.form.load.getdoctype?doctype=Car%20Service%20Record" \
  -o /tmp/child-gd.json -w "HTTP %{http_code}\n"
env/bin/python - <<'PYEOF'
import json
m = json.load(open("/tmp/child-gd.json"))["docs"][0]
fields = {f["fieldname"]: f for f in m.get("fields", [])}
w = fields.get("workshop") or {}
p = fields.get("workshop_phone") or {}
print("  workshop: fieldtype=%s options=%s" % (w.get("fieldtype"), w.get("options")))
print("  workshop_phone: fieldtype=%s fetch_from=%s" % (p.get("fieldtype"), p.get("fetch_from")))
print("  vendor present (should be False):", "vendor" in fields)
PYEOF

echo "== site health / regression =="
curl -s -o /dev/null -w "ping HTTP %{http_code}\n" -H "Host: $SITE" "http://localhost:$PORT/api/method/ping"
curl -s -b /tmp/ws.txt -H "Host: $SITE" -o /dev/null -w "Company HTTP %{http_code}\n" "http://localhost:$PORT/api/resource/Company?limit_page_length=1"
curl -s -b /tmp/ws.txt -H "Host: $SITE" -o /dev/null -w "Vehicle(core) HTTP %{http_code}\n" "http://localhost:$PORT/api/resource/Vehicle?limit_page_length=1"
