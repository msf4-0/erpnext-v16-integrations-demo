#!/usr/bin/env bash
# Final residual-data check + served-JS re-verification after all the
# verification runs (which create and delete their own test records).
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
PORT="${PORT:-8000}"
cd /home/frappe/frappe-bench || exit 1
DB_NAME=$(env/bin/python -c "import json;print(json.load(open('sites/$SITE/site_config.json'))['db_name'])")

echo "== residual rows in the car_tracker doctypes =="
for t in "tabCar" "tabCar Workshop" "tabCar Service Record"; do
  n=$(mariadb -h db -u root -padmin "$DB_NAME" -N -e "select count(*) from \`$t\`;" 2>/dev/null)
  echo "  $t: $n"
done

echo
echo "== series counters =="
mariadb -h db -u root -padmin "$DB_NAME" -e \
  "select name, current from \`tabSeries\` where name in ('CAR-','WS-');" 2>/dev/null

echo
echo "== served __js for Car still carries the confirm logic =="
curl -s -c /tmp/fin.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "http://localhost:$PORT/api/method/login" > /dev/null
curl -s -b /tmp/fin.txt -H "Host: $SITE" \
  "http://localhost:$PORT/api/method/frappe.desk.form.load.getdoctype?doctype=Car" \
  -o /tmp/fin-car.json -w "getdoctype HTTP %{http_code}\n"
env/bin/python - <<'PYEOF'
import json
m = json.load(open("/tmp/fin-car.json"))["docs"][0]
js = m.get("__js") or ""
print("  __js length:", len(js))
for needle in ("distinct_workshop_names", "frappe.db", "frappe.confirm",
               "frappe.validated = false", "last_workshop", "workshops_used"):
    print(f"  contains {needle!r}: {needle in js}")
print("  modified:", m.get("modified"))
PYEOF

echo
echo "== Car Workshop served metadata =="
curl -s -b /tmp/fin.txt -H "Host: $SITE" \
  "http://localhost:$PORT/api/method/frappe.desk.form.load.getdoctype?doctype=Car%20Workshop" \
  -o /tmp/fin-ws.json -w "getdoctype HTTP %{http_code}\n"
env/bin/python - <<'PYEOF'
import json
m = json.load(open("/tmp/fin-ws.json"))["docs"][0]
fields = {f["fieldname"]: f for f in m.get("fields", [])}
print("  module:", m.get("module"), "| autoname:", m.get("autoname"))
print("  status options:", repr(fields["status"].get("options")))
print("  workshop_name unique:", fields["workshop_name"].get("unique"))
print("  'Blacklisted' anywhere in fields:",
      any("Blacklisted" in str(f.get("options")) for f in m.get("fields", [])))
PYEOF

echo
echo "== health =="
curl -s -o /dev/null -w "  ping HTTP %{http_code}\n" -H "Host: $SITE" "http://localhost:$PORT/api/method/ping"
