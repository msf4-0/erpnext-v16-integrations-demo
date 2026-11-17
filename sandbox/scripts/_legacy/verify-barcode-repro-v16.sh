#!/usr/bin/env bash
# Reproduce the Barcode Printing errors on v16 over HTTP (authenticated).
# Runs INSIDE the bench container.
set -uo pipefail
SITE=frontend
B=http://localhost:8000
J=/tmp/bprepro
rm -f "$J.jar"; mkdir -p "$J"

echo "== login =="
curl -s -c "$J.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" \
  -o "$J/login.json" -w "login http=%{http_code}\n"
head -c 300 "$J/login.json"; echo

echo
echo "== 1) run_doc_method class get_item_details (expect permission error) =="
cat > "$J/docmethod.json" <<'JSONEOF'
{"docs":{"doctype":"Barcode Printing","name":"__NEW__","__islocal":1,"company":"__COMPANY__","items":[{"doctype":"Barcode Generator Items","item_code":"__ITEM__","qty":1}]},"method":"get_item_details","args":{"item_code":"__ITEM__","qty":1,"company":"__COMPANY__"}}
JSONEOF
# fill placeholders from DB via console
cat > /tmp/_bpinfo.py <<'PYEOF'
import frappe, json
c = frappe.get_all("Company", limit=1, pluck="name")
i = frappe.get_all("Item", limit=1, pluck="name")
print("MARK", json.dumps({"company": c[0] if c else "", "item": i[0] if i else ""}))
PYEOF
INFO=$(bench --site "$SITE" console < /tmp/_bpinfo.py 2>/dev/null | grep '^MARK' | head -1 | sed 's/^MARK //')
echo "info: $INFO"
COMPANY=$(echo "$INFO" | python3 -c "import sys,json;print(json.load(sys.stdin)['company'])")
ITEM=$(echo "$INFO" | python3 -c "import sys,json;print(json.load(sys.stdin)['item'])")
sed -i "s/__COMPANY__/$COMPANY/g; s/__ITEM__/$ITEM/g" "$J/docmethod.json" "$J/docmethod.json" 2>/dev/null || true
sed -i "s/__COMPANY__/$COMPANY/g; s/__ITEM__/$ITEM/g" "$J/docmethod.json"
echo "payload: $(cat "$J/docmethod.json")"
curl -s -b "$J.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -H "X-Frappe-CSRF-Token: $(grep -o 'csrf_token[^;]*' "$J.jar" | head -1)" \
  -X POST "$B/api/method/frappe.handler.run_doc_method" \
  --data-binary @"$J/docmethod.json" \
  -o "$J/docmethod.out" -w "run_doc_method http=%{http_code}\n"
head -c 800 "$J/docmethod.out"; echo

echo
echo "== 2) make_qrcode on an unsaved doc (expect DoesNotExistError) =="
cat > "$J/qr.json" <<JSONEOF
{"doc":"{\"name\":\"new-barcode-printing-abc\",\"items\":[]}","route":"http://localhost:8000"}
JSONEOF
curl -s -b "$J.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.make_qrcode" \
  --data-binary @"$J/qr.json" -o "$J/qr.out" -w "make_qrcode http=%{http_code}\n"
head -c 800 "$J/qr.out"; echo

echo
echo "== 3) module-level whitelisted get_item_details (the documented broken SQL) =="
curl -s -b "$J.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_item_details" \
  --data '{"frm":{"doc":{"items":[]}}}' -o "$J/mod.out" -w "module get_item_details http=%{http_code}\n"
head -c 800 "$J/mod.out"; echo
