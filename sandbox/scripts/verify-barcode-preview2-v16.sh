#!/usr/bin/env bash
# Verify the on-form Preview sections now render server-side:
#   - get_preview_html returns real /files/*.png <img> for sku/serial/batch
#   - works on an UNSAVED doc too
#   - no jsdelivr / svg / data-uri
#   - content-hash dedup: repeating a call yields the SAME file url
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bpprev2
rm -rf "$J"; mkdir -p "$J"

cat > apps/barcode_shrdc/barcode_shrdc/_prevseed2.py <<'PYEOF'
import json
import frappe


def run():
    # Do NOT assume a fixed doc name exists (a reset/reinstall removes it).
    # Find any Barcode Printing with items, or create one; normalise it so the
    # previews render.
    names = frappe.get_all("Barcode Printing", limit=50, pluck="name")
    d = None
    for n in names:
        candidate = frappe.get_doc("Barcode Printing", n)
        if candidate.items:
            d = candidate
            break
    if d is None:
        company = frappe.get_all("Company", limit=1, pluck="name")
        item = frappe.get_all("Item", limit=1, pluck="name")
        d = frappe.new_doc("Barcode Printing")
        d.company = company[0] if company else None
        d.append("items", {"item_code": item[0] if item else None, "qty": 1})
        d.insert(ignore_permissions=True)
        frappe.db.commit()
    d.show_sku = 1
    for r in d.items:
        if not r.qty:
            r.qty = 1
        if not r.barcode:
            r.barcode = "123456789012"
        if not r.barcode_type:
            r.barcode_type = "EAN13"
        if not r.rate:
            r.rate = 9.5
        r.serial_no = "SN-PREVIEW-0001\nSN-PREVIEW-0002"
        r.batch_no = ""
    d.flags.ignore_validate_update_after_submit = True
    d.save(ignore_permissions=True)
    frappe.db.commit()
    # unsaved-in-memory copy with the same items
    unsaved = {"name": "new-barcode-printing-x", "items": [
        {"item_code": r.item_code, "item_name": r.item_name, "qty": r.qty,
         "rate": r.rate, "barcode": r.barcode, "barcode_type": r.barcode_type,
         "serial_no": r.serial_no, "batch_no": r.batch_no}
        for r in d.items], "serial_barcode_type": "CODE128", "batch_barcode_type": "CODE128"}
    open("/tmp/bpprev2/doc.txt", "w").write(d.name)
    open("/tmp/bpprev2/unsaved.json", "w").write(json.dumps(unsaved))
    print("MARK seeded", d.name, "items", len(d.items))
PYEOF
bench --site "$SITE" execute barcode_shrdc._prevseed2.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f apps/barcode_shrdc/barcode_shrdc/_prevseed2.py
DOC=$(cat "$J/doc.txt")

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o /dev/null -w "login=%{http_code}\n"

preview() { # label kind docjson
  # NOTE: output file must differ from the input file — `curl -o F --data-binary @F`
  # truncates F before reading it.
  curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
    -X POST "$B/api/method/barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_preview_html" \
    --data-binary @"$3" -o "$J/$1.out.json" -w "  $1 http=%{http_code}\n"
  python3 - "$J/$1.out.json" "$1" <<'PYEOF'
import json, sys, re
d = json.load(open(sys.argv[1]))
if "exception" in d:
    print("    EXCEPTION:", d["exception"][:160]); raise SystemExit
h = d.get("message") or ""
print("    %-8s len=%d imgs=%d jsdelivr=%s svg=%s datauri=%s" %
      (sys.argv[2], len(h), h.count("<img"), "jsdelivr" in h, "<svg" in h, "data:image" in h))
print("    urls:", sorted(set(re.findall(r'/files/[A-Za-z0-9_.\-]+', h))))
PYEOF
}

echo
echo "== saved doc: sku / serial / batch previews =="
python3 -c "import json;print(json.dumps({'doc': {'name':'$DOC','items': json.load(open('$J/unsaved.json'))['items'],'serial_barcode_type':'CODE128','batch_barcode_type':'CODE128'},'kind':'sku'}))" > "$J/sku.json"
preview sku sku "$J/sku.json"
python3 -c "import json;print(json.dumps({'doc': {'name':'$DOC','items': json.load(open('$J/unsaved.json'))['items'],'serial_barcode_type':'CODE128','batch_barcode_type':'CODE128'},'kind':'serial'}))" > "$J/serial.json"
preview serial serial "$J/serial.json"
python3 -c "import json;print(json.dumps({'doc': {'name':'$DOC','items': json.load(open('$J/unsaved.json'))['items'],'serial_barcode_type':'CODE128','batch_barcode_type':'CODE128'},'kind':'batch'}))" > "$J/batch.json"
preview batch batch "$J/batch.json"

echo
echo "== UNSAVED doc (the form before save) =="
python3 -c "import json;d=json.load(open('$J/unsaved.json'));print(json.dumps({'doc': d,'kind':'sku'}))" > "$J/unsaved_sku.json"
preview unsaved_sku unsaved "$J/unsaved_sku.json"

echo
echo "== dedup: repeat the same sku preview, expect identical file url =="
cp "$J/sku.json" "$J/sku_again.json"
preview sku_again sku "$J/sku_again.json"
python3 - "$J/sku.out.json" "$J/sku_again.out.json" <<'PYEOF'
import json, re, sys
a = json.load(open(sys.argv[1])).get("message") or ""
b = json.load(open(sys.argv[2])).get("message") or ""
ua = sorted(set(re.findall(r'/files/[A-Za-z0-9_.\-]+', a)))
ub = sorted(set(re.findall(r'/files/[A-Za-z0-9_.\-]+', b)))
print("    dedup identical:", ua == ub, ua, ub)
PYEOF

echo
echo "== fetch the referenced images =="
for u in $(grep -oh '/files/[A-Za-z0-9_.\-]*\.png' "$J"/*.out.json 2>/dev/null | sort -u); do
  curl -s -o /dev/null -w "  $u -> %{http_code} %{content_type}\n" -H "Host: $SITE" "$B$u"
done
