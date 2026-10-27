#!/usr/bin/env bash
# Prove the Device form's client script is delivered AND correct:
#   - __js from getdoctype contains our real handlers
#   - the desk's own js bundle for the doctype resolves our file path
#   - field metadata the JS depends on (read_only computed fields) is right
# This is the rendering check: does the served payload actually contain the
# expected element/content, not merely "no error".
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

curl -s -c /tmp/js2.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' http://localhost:8000/api/method/login > /dev/null

echo "== fetch getdoctype for Device =="
curl -s -b /tmp/js2.txt -H "Host: $SITE" \
  "http://localhost:8000/api/method/frappe.desk.form.load.getdoctype?doctype=Device" \
  -o /tmp/gd2.json -w "HTTP %{http_code}\n"

echo
echo "== assert the delivered __js contains every expected handler =="
python3 - <<'PY'
import json, sys

d = json.load(open("/tmp/gd2.json"))
m = d["docs"][0]
js = m.get("__js") or ""

checks = [
    ('frappe.ui.form.on("Device"', "form event binding"),
    ("refresh(frm)", "refresh handler"),
    ("power_rating_w(frm)", "power_rating_w handler"),
    ("daily_operating_hours(frm)", "daily_operating_hours handler"),
    ("validate(frm)", "validate handler"),
    ("calculate_consumption", "calc function"),
    ("frappe.validated = false", "client-side 24h guard"),
]
ok = True
for needle, label in checks:
    present = needle in js
    ok = ok and present
    print(f"  [{'OK ' if present else 'MISS'}] {label}: {needle!r}")

print(f"\n  served __js length: {len(js)} chars")
print("  source path referenced:", "device.js" in js)

# field metadata: computed fields must be read_only
ro = {f["fieldname"]: f.get("read_only") for f in m.get("fields", [])
      if f["fieldname"].startswith("estimated_")}
print("\n  read_only on computed fields:", ro)
allro = all(v == 1 for v in ro.values())
print(f"  [{'OK ' if allro else 'MISS'}] all computed fields read_only")

print("\nRESULT:", "PASS" if (ok and allro) else "FAIL")
sys.exit(0 if (ok and allro) else 1)
PY
