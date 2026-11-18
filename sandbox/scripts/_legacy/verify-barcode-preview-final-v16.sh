#!/usr/bin/env bash
# Final preview-focused integrity checks:
#  - served doctype JS has no CDN getScript calls and DOES call get_preview_html
#  - get_preview_html is whitelisted (reachable over HTTP, already 200 above)
#  - host_name is set and resolvable
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bpfinal
mkdir -p "$J"

echo "== served doctype JS (as the browser gets it) =="
curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o /dev/null -w "  login=%{http_code}\n"
curl -s -b "$J/jar" -H "Host: $SITE" \
  "$B/api/method/frappe.desk.form.load.getdoctype?doctype=Barcode%20Printing&with_parent=1" \
  -o "$J/gd.json" -w "  getdoctype http=%{http_code}\n"
python3 - "$J/gd.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
txt = json.dumps(d)
checks = {
    "getScript (old CDN path)": "$.getScript" in txt,
    "cdn.jsdelivr.net": "cdn.jsdelivr.net" in txt,
    "get_preview_html call": "get_preview_html" in txt,
    "JsBarcode": "JsBarcode(" in txt,
}
for k, v in checks.items():
    print("  %-26s %s" % (k, v))
PYEOF

echo
echo "== whitelist: get_preview_html importable + whitelisted =="
cat > apps/barcode_shrdc/barcode_shrdc/_wl.py <<'PYEOF'
import importlib
from frappe import whitelisted
m = importlib.import_module("barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing")
for fn in ("get_preview_html", "get_barcode_image", "get_qr_image", "make_qrcode"):
    f = getattr(m, fn, None)
    print("MARK %-20s whitelisted=%s" % (fn, f in whitelisted if f else "MISSING"))
PYEOF
bench --site "$SITE" execute barcode_shrdc._wl.run 2>&1 | grep '^MARK' | sed 's/^/  /'
rm -f apps/barcode_shrdc/barcode_shrdc/_wl.py

echo
echo "== host_name =="
grep -o '"host_name"[^,}]*' sites/$SITE/site_config.json | sed 's/^/  /'
