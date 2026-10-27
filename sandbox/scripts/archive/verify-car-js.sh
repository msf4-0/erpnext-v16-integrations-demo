#!/usr/bin/env bash
# Prove the Car form's client script is delivered AND correct on v16:
#   - __js from getdoctype contains our real handlers
#   - field metadata the JS depends on (read_only derived fields) is right
# v16 delivers an app doctype's .js INLINE via getdoctype's __js field —
# /assets/car_tracker/js/car.js 404s and that is expected, not a failure.
# NOTE: frappe.client.get_js returns 500 on v16; use
# frappe.desk.form.load.getdoctype (the desk's own endpoint), as robotics_lab
# verification established.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
PORT="${PORT:-8000}"
cd /home/frappe/frappe-bench || exit 1

curl -s -c /tmp/carjs.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "http://localhost:$PORT/api/method/login" > /dev/null

echo "== fetch getdoctype for Car =="
curl -s -b /tmp/carjs.txt -H "Host: $SITE" \
  "http://localhost:$PORT/api/method/frappe.desk.form.load.getdoctype?doctype=Car" \
  -o /tmp/car-gd.json -w "HTTP %{http_code}\n"

echo
echo "== assert the delivered __js contains every expected handler =="
env/bin/python - <<'PYEOF'
import sys

import json

d = json.load(open("/tmp/car-gd.json"))
m = d["docs"][0]
js = m.get("__js") or ""

checks = [
    ('frappe.ui.form.on("Car"', "parent form event binding"),
    ('frappe.ui.form.on("Car Service Record"', "child form event binding"),
    ("compute_service_summary", "summary calc function"),
    ("service_records_remove", "child row removal handler"),
    ("last_oil_change_date", "oil-change summary field"),
    ("last_maintenance_date", "maintenance summary field"),
    ("service_status", "status classification"),
    ("apply_pair", "shared next-due helper"),
]
ok = True
for needle, label in checks:
    present = needle in js
    ok = ok and present
    print(f"  [{'OK ' if present else 'MISS'}] {label}: {needle!r}")

print(f"\n  served __js length: {len(js)} chars")
print("  references car.js:", "car.js" in js)

# metadata: every derived field must be read_only
derived = [
    "last_oil_change_date", "last_oil_change_mileage",
    "next_oil_change_due_date", "next_oil_change_due_mileage",
    "last_maintenance_date", "last_maintenance_mileage",
    "next_maintenance_due_date", "next_maintenance_due_mileage",
    "service_records_count", "total_maintenance_cost", "service_status",
]
ro = {f["fieldname"]: f.get("read_only") for f in m.get("fields", []) if f["fieldname"] in derived}
print("\n  read_only on derived fields:", ro)
allro = len(ro) == len(derived) and all(v == 1 for v in ro.values())
print(f"  [{'OK ' if allro else 'MISS'}] all derived fields read_only")

# the child table link must point at our child doctype
child = [f for f in m.get("fields", []) if f["fieldname"] == "service_records"]
child_ok = bool(child) and child[0].get("options") == "Car Service Record"
print(f"  [{'OK ' if child_ok else 'MISS'}] service_records -> Car Service Record")

print("\nRESULT:", "PASS" if (ok and allro and child_ok) else "FAIL")
sys.exit(0 if (ok and allro and child_ok) else 1)
PYEOF
