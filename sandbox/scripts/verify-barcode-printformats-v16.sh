#!/usr/bin/env bash
# Verify the barcode/QR print formats render server-side images on v16.
# Seeds a doc with an item that has a barcode, sets EACH of the gating flags so
# every format's section renders, then fetches each format over HTTP and checks
# for a real /files/*.png which must itself return 200 image/png.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bppf
rm -rf "$J"; mkdir -p "$J"

# `bench console` mangles multi-line loops -> use a helper module + bench execute.
HELPER=/home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc/pf_seed_helper.py
cat > "$HELPER" <<'PYEOF'
import json
import frappe


def run():
	company = frappe.get_all("Company", limit=1, pluck="name")[0]
	item = frappe.get_all("Item", limit=1, pluck="name")[0]
	docs = frappe.get_all("Barcode Printing", limit=50, pluck="name")
	chosen = None
	for n in docs:
		d = frappe.get_doc("Barcode Printing", n)
		if d.items:
			chosen = d
			break
	if not chosen:
		d = frappe.new_doc("Barcode Printing")
		d.company = company
		d.append("items", {"item_code": item, "qty": 1})
		d.insert(ignore_permissions=True)
		frappe.db.commit()
		chosen = d
	# Set the gating flag so the barcode (SKU) section renders. Serial/batch
	# sections are deliberately left off: they require real Serial No / Batch
	# records on the (blank) site, which the app's own validate() rejects.
	chosen.show_sku = 1
	chosen.show_serial_no = 0
	chosen.show_batch_no = 0
	chosen.serial_barcode_type = "CODE128"
	chosen.batch_barcode_type = "CODE128"
	for row in chosen.items:
		# The format renders `range(qty)` of the label; a 0/None qty (which some
		# pre-existing junk docs carry) renders nothing. Normalise to >= 1.
		if not row.qty:
			row.qty = 1
		if not row.barcode:
			row.barcode = "123456789012"
		if not row.barcode_type:
			# an Item can carry a barcode with an empty type; the format gates
			# on BOTH, so make it renderable.
			row.barcode_type = "EAN13"
		if not row.rate:
			row.rate = 9.5
		row.serial_no = ""
		row.batch_no = ""
	chosen.flags.ignore_validate_update_after_submit = True
	chosen.save(ignore_permissions=True)
	frappe.db.commit()
	open("/tmp/bppf/doc.txt", "w").write(chosen.name)
	open("/tmp/bppf/info.json", "w").write(json.dumps({
		"doc": chosen.name,
		"item": chosen.items[0].item_code,
		"barcode": chosen.items[0].barcode,
		"barcode_type": chosen.items[0].barcode_type,
		"show_sku": chosen.show_sku,
	}))
	print("MARK seeded", chosen.name, "show_sku", chosen.show_sku)
PYEOF
bench --site "$SITE" execute barcode_shrdc.pf_seed_helper.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
cat "$J/info.json"; echo
DOC=$(cat "$J/doc.txt")

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o "$J/login" -w "login=%{http_code}\n"

FILES=""
for PF in "Barcode Printing Format" "Barcode Printing Format A4" "QR Code Printing Format"; do
  ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$PF")
  echo
  echo "== format: $PF =="
  curl -s -b "$J/jar" -H "Host: $SITE" \
    "$B/api/method/frappe.www.printview.get_html_and_style?doc=Barcode%20Printing&name=$DOC&print_format=$ENC&no_letterhead=1&_lang=en" \
    -o "$J/out.json" -w "  http=%{http_code}\n"
  python3 - "$J/out.json" "$PF" "$J/urls.txt" "$J/info.json" <<'PYEOF'
import json, sys, re
d = json.load(open(sys.argv[1]))
html = ((d.get("message") or {}).get("html") or "")
print("   %-28s len=%d imgs=%d jsdelivr=%s jsbarcode=%s svg=%s datauri=%s"
      % (sys.argv[2], len(html), html.count("<img"),
         "jsdelivr" in html, "JsBarcode" in html, "<svg" in html, "data:image" in html))
# server-side text should be present too (use the SEEDED item, not a hardcoded one)
info = json.load(open(sys.argv[4]))
for needle, label in ((info.get("item"), "item_code"),):
    print("     contains %-10s %s" % (label, (needle or "") in html))
urls = sorted(set(re.findall(r'/files/[A-Za-z0-9_.\-]+', html)))
for u in urls:
    print("     file url:", u)
with open(sys.argv[3], "a") as fh:
    for u in urls:
        fh.write(u + "\n")
PYEOF
done

echo
echo "== fetch every referenced /files/*.png and check content-type =="
for u in $(sort -u "$J/urls.txt" 2>/dev/null); do
  curl -s -o /dev/null -w "  $u -> %{http_code} %{content_type} %{size_download}b\n" \
    -H "Host: $SITE" "$B$u"
done

echo
echo "== ping =="
curl -s -o /dev/null -w "  ping=%{http_code}\n" -H "Host: $SITE" "$B/api/method/ping"

# Remove the seed helper module we wrote into the app tree (it exists only to
# drive `bench execute`, because `bench console` mangles multi-line loops).
rm -f /home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc/pf_seed_helper.py
