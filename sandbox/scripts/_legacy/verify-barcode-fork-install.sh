#!/usr/bin/env bash
# WS1 PROOF: install barcode_shrdc FROM THE DURABLE FORK (fix/v16-compat) and
# confirm the v16 runtime bugs are fixed WITHOUT running fix-barcode-v16.sh.
#
# Steps: stage the fork -> root chown -> root render-deps -> install from dir ->
# then exercise the exact paths that used to fail.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bfork
rm -rf "$J"; mkdir -p "$J"

echo "########## 1) root: render deps (libcairo2-dev + reportlab/rlPyCairo) ##########"
echo "(run separately with -u root before this script if not done)"

echo
echo "########## 2) install from the fork directory ##########"
/tmp/scripts/install-app.sh barcode_shrdc /tmp/barcode-shrdc-v16 16 /tmp/recipes/barcode_shrdc.yaml > "$J/install.log" 2>&1
echo "  rc=$?"
grep -E "Local source|placed app at|converting|dropped|registered|REST status|ERROR|Traceback|Skipping fixture" "$J/install.log" | sed 's/^/  /'

echo
echo "########## 3) confirm NO post-install patch was applied ##########"
echo "  (nothing from fix-barcode-v16.sh was run; checking the source proves it)"
APP=/home/frappe/frappe-bench/apps/barcode_shrdc
echo "  class whitelist:      $(grep -c '@frappe.whitelist()' "$APP/barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.py")"
echo "  get_preview_html def: $(grep -c 'def get_preview_html' "$APP/barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.py")"
echo "  jinja hook:           $(grep -c 'jinja = {' "$APP/barcode_shrdc/hooks.py")"
echo "  js jdsdelivr left:    $(grep -c 'cdn.jsdelivr' "$APP/barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.js")"
echo "  client_script fixture: $(ls "$APP/barcode_shrdc/fixtures/" | grep -c client_script)"

echo
echo "########## 4) exercise the previously-broken paths over HTTP ##########"
curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o /dev/null -w "  login=%{http_code}\n"

# a) class get_item_details on a NEW doc (was 403)
python3 -c "import json;print(json.dumps({'docs':{'doctype':'Barcode Printing','name':'new-barcode-printing-1','__islocal':1,'company':'t','items':[{'doctype':'Barcode Generator Items','item_code':'SKU010','qty':1}]},'method':'get_item_details','args':{'item_code':'SKU010','qty':1,'company':'t'}}))" > "$J/a.json"
curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/frappe.handler.run_doc_method" --data-binary @"$J/a.json" \
  -o "$J/a.out" -w "  a) new-doc get_item_details http=%{http_code} (was 403)\n"

# b) make_qrcode on unsaved (was 404 DoesNotExistError)
python3 -c "import json;print(json.dumps({'doc':json.dumps({'name':'new-barcode-printing-1','items':[]}),'route':'$B'}))" > "$J/b.json"
curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.make_qrcode" \
  --data-binary @"$J/b.json" -o "$J/b.out" -w "  b) unsaved make_qrcode http=%{http_code} (was 404)\n"
grep -o 'Please save the document[^"]*' "$J/b.out" | head -1 | sed 's/^/     -> /'

# c) module-level get_item_details (was 500)
echo '{"frm":{"doc":{"items":[{"item_code":"SKU010"}],"item_code":"SKU010"}}}' > "$J/c.json"
curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_item_details" \
  --data-binary @"$J/c.json" -o "$J/c.out" -w "  c) module get_item_details http=%{http_code} (was 500)\n"

# d) get_preview_html (new; was client-side CDN)
python3 -c "import json;print(json.dumps({'doc':{'name':'x','serial_barcode_type':'CODE128','items':[{'item_code':'SKU010','item_name':'Camera','qty':1,'rate':9.5,'barcode':'123456789012','barcode_type':'EAN13'}]},'kind':'sku'}))" > "$J/d.json"
curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_preview_html" \
  --data-binary @"$J/d.json" -o "$J/d.out" -w "  d) get_preview_html http=%{http_code}\n"
python3 -c "import json;d=json.load(open('$J/d.out'));h=d.get('message') or '';print('     imgs:', h.count('<img'), '| jsdelivr:', 'jsdelivr' in h)" 2>/dev/null || true

echo
echo "########## 5) print formats + PDF (was blank / HostNotFoundError) ##########"
bash /tmp/scripts/verify-barcode-pdf-v16.sh 2>&1 | grep -E 'http=|pdf=' | sed 's/^/  /'

echo
echo "== ping =="
curl -s -o /dev/null -w "  ping=%{http_code}\n" -H "Host: $SITE" "$B/api/method/ping"
