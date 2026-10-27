#!/usr/bin/env bash
# Clean up diagnostic test records left by verify-car-controller.sh, then run a
# final consolidated health check for the car_tracker app on the live v16 site.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
PORT="${PORT:-8000}"
cd /home/frappe/frappe-bench || exit 1

echo "== remove diagnostic test records =="
APP_DIR=apps/car_tracker/car_tracker
mkdir -p "$APP_DIR/_diag"
cat > "$APP_DIR/_diag/__init__.py" <<'PYEOF'
PYEOF
cat > "$APP_DIR/_diag/run.py" <<'PYEOF'
import frappe


def cleanup():
	frappe.set_user("Administrator")
	removed = 0
	for name, plate in frappe.get_all("Car", fields=["name", "license_plate"], as_list=True):
		if (plate or "").startswith("DIAG-") or (plate or "").startswith("TEST-"):
			frappe.delete_doc("Car", name, force=1, ignore_permissions=True)
			removed += 1
	print("removed diagnostic cars:", removed)
	print("cars remaining:", frappe.db.count("Car"))
	for row in frappe.get_all("Car", fields=["name", "license_plate"], as_list=True):
		print("  ", row)
PYEOF

bench --site "$SITE" execute car_tracker._diag.run.cleanup
rm -rf "$APP_DIR/_diag"

echo
echo "== list-apps =="
bench --site "$SITE" list-apps

echo
echo "== site health =="
curl -s -o /dev/null -w "ping HTTP %{http_code}\n" -H "Host: $SITE" "http://localhost:$PORT/api/method/ping"
curl -s -c /tmp/final.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "http://localhost:$PORT/api/method/login" > /dev/null
curl -s -b /tmp/final.txt -H "Host: $SITE" -o /dev/null -w "GET Car HTTP %{http_code}\n" \
  "http://localhost:$PORT/api/resource/Car?limit_page_length=1"
curl -s -b /tmp/final.txt -H "Host: $SITE" -o /dev/null -w "Company HTTP %{http_code}\n" \
  "http://localhost:$PORT/api/resource/Company?limit_page_length=1"
curl -s -b /tmp/final.txt -H "Host: $SITE" -o /dev/null -w "Item HTTP %{http_code}\n" \
  "http://localhost:$PORT/api/resource/Item?limit_page_length=1"
curl -s -b /tmp/final.txt -H "Host: $SITE" -o /dev/null -w "Vehicle (core) HTTP %{http_code}\n" \
  "http://localhost:$PORT/api/resource/Vehicle?limit_page_length=1"

echo
echo "== served doctype modified timestamp =="
curl -s -b /tmp/final.txt -H "Host: $SITE" \
  "http://localhost:$PORT/api/method/frappe.desk.form.load.getdoctype?doctype=Car" \
  -o /tmp/final-gd.json -w "HTTP %{http_code}\n"
env/bin/python - <<'PYEOF'
import json
m = json.load(open("/tmp/final-gd.json"))["docs"][0]
print("modified:", m.get("modified"))
print("__js length:", len(m.get("__js") or ""))
print("has compute_service_summary:", "compute_service_summary" in (m.get("__js") or ""))
PYEOF
