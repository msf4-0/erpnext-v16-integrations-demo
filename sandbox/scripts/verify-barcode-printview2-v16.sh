#!/usr/bin/env bash
# Seed a Barcode Printing doc WITH items (barcode + serial), then render both
# print formats and check for images. Read-only w.r.t. source.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bpprint2
mkdir -p "$J"

cat > /tmp/_seedfull.py <<'PYEOF'
import frappe, json
company = frappe.get_all("Company", limit=1, pluck="name")[0]
item = frappe.get_all("Item", limit=1, pluck="name")[0]
out = {"company": company, "item": item}
# pick/create a doc with items
docs = frappe.get_all("Barcode Printing", limit=20, pluck="name")
chosen = None
for n in docs:
    d = frappe.get_doc("Barcode Printing", n)
    if d.items:
        chosen = d
        break
if not chosen:
    d = frappe.new_doc("Barcode Printing")
    d.company = company
    d.append("items", {"item_code": item, "qty": 1, "barcode": "123456789012", "barcode_type": "EAN13", "rate": 9.5})
    d.insert(ignore_permissions=True)
    frappe.db.commit()
    chosen = d
out["doc"] = chosen.name
out["n_items"] = len(chosen.items)
if chosen.items:
    out["row"] = {k: chosen.items[0].get(k) for k in ("item_code","qty","barcode","barcode_type","rate","serial_no","item_name")}
open("/tmp/bpprint2/info.json","w").write(json.dumps(out, default=str))
PYEOF
bench --site "$SITE" console < /tmp/_seedfull.py > /dev/null 2>&1
cat "$J/info.json"; echo
DOC=$(python3 -c "import json;print(json.load(open('$J/info.json'))['doc'])")

# ensure global Barcode Configuration / printer settings values look sane
cat > /tmp/_cfg.py <<'PYEOF'
import frappe
open("/tmp/bpprint2/cfg.txt","w").write(
    "Barcode Configuration: %s\n" % (frappe.get_doc("Barcode Configuration").as_dict() if frappe.db.exists("Barcode Configuration") else "MISSING"))
PYEOF
bench --site "$SITE" console < /tmp/_cfg.py > /dev/null 2>&1
cat "$J/cfg.txt"; echo

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o "$J/login" -w "login=%{http_code}\n"

# show_sku so the barcode section renders
for PF in "Barcode Printing Format" "Barcode Printing Format A4" "QR Code Printing Format"; do
  ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$PF")
  echo
  echo "== format: $PF =="
  curl -s -b "$J/jar" -H "Host: $SITE" \
    "$B/api/method/frappe.www.printview.get_html_and_style?doc=Barcode%20Printing&name=$DOC&print_format=$ENC&no_letterhead=1&_lang=en" \
    -o "$J/out.json" -w "http=%{http_code}\n"
  python3 - "$J/out.json" <<'PYEOF'
import json, sys, re
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("  (not json)", e); raise SystemExit
html = ((d.get("message") or {}).get("html") or "")
print("  html len:", len(html))
for needle in ("<img", "jsdelivr", "JsBarcode", "<svg", "data:image"):
    print("   contains %-14s %s" % (needle, needle in html))
print("   file urls:", sorted(set(re.findall(r'/files/[A-Za-z0-9_.\-]+', html)))[:8])
PYEOF
done
