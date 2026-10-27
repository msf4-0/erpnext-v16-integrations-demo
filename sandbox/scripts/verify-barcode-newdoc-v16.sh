#!/usr/bin/env bash
# Reproduce the FULL set of Barcode Printing form errors a user hits on a NEW
# document on ERPNext v16 (authenticated HTTP, as the browser does).
# Read-only w.r.t. source. Runs INSIDE the bench container.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bpnew
rm -rf "$J"; mkdir -p "$J"

# --- discover a company + item (write via bench console, robust to console noise)
cat > /tmp/_bpnew_info.py <<'PYEOF'
import frappe, json
c = frappe.get_all("Company", limit=1, pluck="name")
i = frappe.get_all("Item", limit=1, pluck="name")
open("/tmp/bpnew/info.json","w").write(json.dumps(
    {"company": c[0] if c else "", "item": i[0] if i else ""}))
PYEOF
bench --site "$SITE" console < /tmp/_bpnew_info.py >/dev/null 2>&1
COMPANY=$(python3 -c "import json;print(json.load(open('$J/info.json'))['company'])")
ITEM=$(python3 -c "import json;print(json.load(open('$J/info.json'))['item'])")
echo "company=[$COMPANY] item=[$ITEM]"

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" \
  -o "$J/login" -w "login=%{http_code}\n"

post() { # name url file
  curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
    -X POST "$2" --data-binary @"$3" -o "$J/$1.out" -w "$1 http=%{http_code}\n"
}

echo
echo "== 1) NEW (unsaved) doc: select item -> run_doc_method get_item_details =="
cat > "$J/1.json" <<JSONEOF
{"docs":{"doctype":"Barcode Printing","name":"new-barcode-printing-1","__islocal":1,"company":"$COMPANY","items":[{"doctype":"Barcode Generator Items","item_code":"$ITEM","qty":1}]},"method":"get_item_details","args":{"item_code":"$ITEM","qty":1,"company":"$COMPANY"}}
JSONEOF
post 1 "$B/api/method/frappe.handler.run_doc_method" "$J/1.json"
head -c 500 "$J/1.out"; echo

echo
echo "== 2) create_qr on unsaved doc (make_qrcode) =="
cat > "$J/2.json" <<JSONEOF
{"doc":"{\"name\":\"new-barcode-printing-1\",\"company\":\"$COMPANY\",\"items\":[]}","route":"$B"}
JSONEOF
post 2 "$B/api/method/barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.make_qrcode" "$J/2.json"
head -c 500 "$J/2.out"; echo

echo
echo "== 3) module-level get_item_details (dead fn, reachable over HTTP) =="
cat > "$J/3.json" <<JSONEOF
{"frm":{"doc":{"items":[{"item_code":"$ITEM"}],"item_code":"$ITEM"}}}
JSONEOF
post 3 "$B/api/method/barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_item_details" "$J/3.json"
head -c 500 "$J/3.out"; echo

echo
echo "== 4) Get items barcode: search_item_serial_or_batch_or_barcode_number =="
cat > "$J/4.json" <<JSONEOF
{"search_value":"nope","item":"{\"item_code\":\"$ITEM\"}"}
JSONEOF
post 4 "$B/api/method/barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.search_item_serial_or_batch_or_barcode_number" "$J/4.json"
head -c 500 "$J/4.out"; echo

echo
echo "== 5) create_barcode_printing (args the app actually sends) =="
cat > "$J/5.json" <<JSONEOF
{"throw_if_missing":true,"se_id":null,"pr_id":null}
JSONEOF
post 5 "$B/api/method/barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.create_barcode_printing" "$J/5.json"
head -c 300 "$J/5.out"; echo

echo
echo "== 6) print view: 3 barcode formats on an items doc =="
cat > /tmp/_bpnew_seed.py <<'PYEOF'
import frappe, json
company = frappe.get_all("Company", limit=1, pluck="name")[0]
item = frappe.get_all("Item", limit=1, pluck="name")[0]
docs = frappe.get_all("Barcode Printing", limit=20, pluck="name")
chosen = None
for n in docs:
    d = frappe.get_doc("Barcode Printing", n)
    if d.items:
        chosen = d; break
if not chosen:
    d = frappe.new_doc("Barcode Printing")
    d.company = company
    d.append("items", {"item_code": item, "qty": 1,
                       "barcode": "123456789012", "barcode_type": "EAN13", "rate": 9.5})
    d.insert(ignore_permissions=True)
    frappe.db.commit()
    chosen = d
open("/tmp/bpnew/doc.txt","w").write(chosen.name)
PYEOF
bench --site "$SITE" console < /tmp/_bpnew_seed.py >/dev/null 2>&1
DOC=$(cat "$J/doc.txt")
echo "doc=$DOC"
for PF in "Barcode Printing Format" "Barcode Printing Format A4" "QR Code Printing Format"; do
  ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$PF")
  curl -s -b "$J/jar" -H "Host: $SITE" \
    "$B/api/method/frappe.www.printview.get_html_and_style?doc=Barcode%20Printing&name=$DOC&print_format=$ENC&no_letterhead=1&_lang=en" \
    -o "$J/pf.json" -w "  $PF http=%{http_code}\n"
  python3 - "$J/pf.json" "$PF" <<'PYEOF'
import json, sys, re
d = json.load(open(sys.argv[1]))
html = ((d.get("message") or {}).get("html") or "")
print("   %-28s len=%d imgs=%d jsdelivr=%s jsbarcode=%s svg=%s datauri=%s get_barcode_image=%s get_qr_image=%s doc.qrcodes=%s"
      % (sys.argv[2], len(html), html.count("<img"),
         "jsdelivr" in html, "JsBarcode" in html, "<svg" in html,
         "data:image" in html, "get_barcode_image" in html,
         "get_qr_image" in html, "doc.qrcodes" in html))
for m in sorted(set(re.findall(r'/files/[A-Za-z0-9_.\-]+', html)))[:6]:
    print("     file url:", m)
PYEOF
done

echo
echo "== 7) ping =="
curl -s -o /dev/null -w "  ping=%{http_code}\n" -H "Host: $SITE" "$B/api/method/ping"
