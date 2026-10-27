#!/usr/bin/env bash
# Verify the SAMPLE DATA the way a user/API would see it, and confirm the
# inactive-workshop warning actually fires for the one car (BMW / CAR-0017)
# whose history references the inactive workshop.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
PORT="${PORT:-8000}"
cd /home/frappe/frappe-bench || exit 1

curl -s -c /tmp/sm.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "http://localhost:$PORT/api/method/login" > /dev/null

echo "== REST: Car Workshop list =="
curl -s -b /tmp/sm.txt -H "Host: $SITE" -o /tmp/sm-ws.json -w "HTTP %{http_code}\n" \
  "http://localhost:$PORT/api/resource/Car%20Workshop?limit_page_length=0&fields=%5B%22name%22%2C%22workshop_name%22%2C%22status%22%2C%22city%22%5D"
env/bin/python - <<'PYEOF'
import json
for r in json.load(open("/tmp/sm-ws.json"))["data"]:
    print("  %-8s %-32s [%s] %s" % (r["name"], r["workshop_name"], r["status"], r.get("city") or "-"))
PYEOF

echo
echo "== REST: Car list with derived fields =="
curl -s -b /tmp/sm.txt -H "Host: $SITE" -o /tmp/sm-cars.json -w "HTTP %{http_code}\n" \
  "http://localhost:$PORT/api/resource/Car?limit_page_length=0&fields=%5B%22name%22%2C%22license_plate%22%2C%22make%22%2C%22last_workshop%22%2C%22workshops_used%22%2C%22service_status%22%5D&order_by=name"
env/bin/python - <<'PYEOF'
import json
for r in json.load(open("/tmp/sm-cars.json"))["data"]:
    print("  %-9s %-9s %-8s last_ws=%-8s used=%s status=%s" % (
        r["name"], r["license_plate"], r["make"],
        r.get("last_workshop") or "-", r.get("workshops_used"), r.get("service_status")))
PYEOF

echo
echo "== REST: one Car with its full child table (looked up by plate) =="
curl -s -b /tmp/sm.txt -H "Host: $SITE" -o /tmp/sm-bmw.json -w "HTTP %{http_code}\n" \
  "http://localhost:$PORT/api/resource/Car?limit_page_length=1&filters=%5B%5B%22license_plate%22%2C%22%3D%22%2C%22MNO%207890%22%5D%5D&fields=%5B%22name%22%5D"
BMW=$(env/bin/python -c "import json;d=json.load(open('/tmp/sm-bmw.json'))['data'];print(d[0]['name'] if d else '')")
echo "  BMW car name: $BMW"
curl -s -b /tmp/sm.txt -H "Host: $SITE" -o /tmp/sm-bmw.json -w "HTTP %{http_code}\n" \
  "http://localhost:$PORT/api/resource/Car/$BMW"
env/bin/python - <<'PYEOF'
import json
d = json.load(open("/tmp/sm-bmw.json"))["data"]
print("  %s %s %s  workshops_used=%s last_workshop=%s" % (
    d["name"], d["make"], d["model"], d["workshops_used"], d["last_workshop"]))
for r in d["service_records"]:
    print("    %s  %-20s %7s km  ws=%-8s phone=%-14s %s" % (
        r["service_date"], r["service_type"], r["odometer"],
        r["workshop"], r.get("workshop_phone") or "-", r["cost"]))
PYEOF

echo
echo "== does saving the BMW raise the INACTIVE-workshop warning? =="
APP_DIR=apps/car_tracker/car_tracker
mkdir -p "$APP_DIR/_chk"
cat > "$APP_DIR/_chk/__init__.py" <<'PYEOF'
PYEOF
cat > "$APP_DIR/_chk/run.py" <<'PYEOF'
import frappe


def check():
	frappe.set_user("Administrator")
	name = frappe.db.get_value("Car", {"license_plate": "MNO 7890"}, "name")
	doc = frappe.get_doc("Car", name)
	frappe.local.message_log = []
	doc.run_method("validate")
	msgs = [m.get("message", "") for m in (frappe.local.message_log or [])]
	frappe.local.message_log = []
	for m in msgs:
		print("  MESSAGE:", m)
	print("  car:", name)
	print("  inactive warning present:", any("inactive workshop" in m.lower() for m in msgs))

	# And confirm a normal save of the BMW still succeeds.
	doc.save(ignore_permissions=True)
	print("  BMW re-saved OK; status =", doc.service_status)
PYEOF
bench --site "$SITE" execute car_tracker._chk.run.check
rm -rf "$APP_DIR/_chk"

echo
echo "== health =="
curl -s -o /dev/null -w "  ping HTTP %{http_code}\n" -H "Host: $SITE" "http://localhost:$PORT/api/method/ping"
