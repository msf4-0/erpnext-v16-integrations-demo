#!/usr/bin/env bash
# Determine how v16 ACTUALLY delivers an app-shipped doctype .js to the desk,
# then prove OUR device.js is in that pipeline. Checking
# /assets/robotics_lab/js/device.js was wrong (404) — that is not the URL the
# desk uses, so prove the real one instead of assuming.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

echo "== A. does the app build system bundle doctype js? =="
echo "-- frappe esbuild config: how are doctype js files discovered? --"
ls apps/frappe/esbuild/ 2>/dev/null
grep -rn "doctype" apps/frappe/esbuild/*.js 2>/dev/null | head -20

echo
echo "== B. what bundles were produced, and does any contain device.js? =="
find sites/assets -name '*.bundle.js' 2>/dev/null | head -10
echo "-- grep the built bundles for our doctype name --"
grep -rl 'frappe.ui.form.on("Device"' sites/assets 2>/dev/null | head -5

echo
echo "== C. getdoctype API: what does the desk actually receive for Device? =="
curl -s -c /tmp/js_ck.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' http://localhost:8000/api/method/login > /dev/null
curl -s -b /tmp/js_ck.txt -H "Host: $SITE" \
  "http://localhost:8000/api/method/frappe.desk.form.load.getdoctype?doctype=Device" \
  -o /tmp/getdoctype.json -w "HTTP %{http_code}\n"
python3 - <<'PY'
import json
d = json.load(open("/tmp/getdoctype.json"))
docs = d.get("docs", [])
if docs:
    m = docs[0]
    for k in ("name", "module", "__js", "js", "app", "custom"):
        if k in m:
            print(f"  {k} = {str(m[k])[:120]!r}")
print("  top-level keys:", list(d.keys()))
PY

echo
echo "== D. the app's compiled JS entrypoint (if the app ships one) =="
find sites/assets/robotics_lab -type f 2>/dev/null | head -20

echo
echo "== E. direct fetch of the doctype js the way frappe serves app files =="
for U in \
  "/assets/robotics_lab/js/device.js" \
  "/api/method/frappe.client.get_js?doctype=Device" \
  ; do
  printf "  %-55s -> " "$U"
  curl -s -b /tmp/js_ck.txt -H "Host: $SITE" -o /dev/null -w "%{http_code}\n" "http://localhost:8000$U"
done
