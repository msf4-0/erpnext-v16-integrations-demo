#!/usr/bin/env bash
# Durability proof: reset the app's edited files back to upstream (git checkout),
# then re-apply the tracked fix scripts and re-verify. This simulates what a
# fresh container recreate gives you (upstream master), WITHOUT recreating the
# container. Proves fix-barcode-v16.sh + the tracked JSON are self-sufficient.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
APP=apps/barcode_shrdc

echo "== reset app files to upstream (simulates a fresh clone) =="
( cd "$APP" && git checkout -- \
    barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.py \
    barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.js \
    barcode_shrdc/hooks.py \
    barcode_shrdc/fixtures/print_format.json ) && echo "  reset OK"

echo
echo "== confirm upstream state (markers gone) =="
grep -c "def get_barcode_image" barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.py 2>/dev/null || true
grep -c "typeof item.serial_no" barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.js 2>/dev/null || true
grep -c "jinja = {" barcode_shrdc/hooks.py 2>/dev/null || true

echo
echo "== also reset the DB print formats to the (now upstream) fixture state =="
cat > "$APP/barcode_shrdc/_reset_pf.py" <<'PYEOF'
import json
import frappe


def run():
    now = frappe.utils.now()
    fixed = json.load(open("/tmp/_upstream_pf.json"))
    for rec in fixed:
        n = rec["name"]
        if frappe.db.exists("Print Format", n):
            for k in ("html", "css", "format_data"):
                frappe.db.set_value("Print Format", n, k, rec.get(k))
            frappe.db.set_value("Print Format", n, "modified", now)
            print("MARK reset", n)
    frappe.db.commit()
    frappe.clear_cache()
PYEOF
env/bin/python - apps/barcode_shrdc/barcode_shrdc/fixtures/print_format.json /tmp/_upstream_pf.json <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
WANT = {"Barcode Printing Format", "Barcode Printing Format A4", "QR Code Printing Format"}
keep = [r for r in d if r.get("name") in WANT and r.get("module") == "Barcode Shrdc"]
json.dump(keep, open(sys.argv[2], "w"))
print("upstream pf records:", len(keep))
PYEOF
bench --site frontend execute barcode_shrdc._reset_pf.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f "$APP/barcode_shrdc/_reset_pf.py"

echo
echo "== re-apply the tracked fix =="
bash /tmp/scripts/fix-barcode-v16.sh > /tmp/reapply.log 2>&1
echo "  rc=$?"
grep -E "PATCHED|guarded|removed|-> scan_barcode|v16 override|jinja hook ADDED|updated|helper modules removed|serve up" /tmp/reapply.log | sed 's/^/  /'

echo
echo "== re-verify =="
bash /tmp/scripts/verify-barcode-newdoc-v16.sh > /tmp/reverify_newdoc.log 2>&1
grep -E "^1 http=|^2 http=|^3 http=|^5 http=|file url|ping=" /tmp/reverify_newdoc.log | sed 's/^/  /'
rm -f /tmp/bppf/urls.txt
bash /tmp/scripts/verify-barcode-printformats-v16.sh > /tmp/reverify_pf.log 2>&1
grep -E "imgs=|contains item_name|-> 200 image/png|ping=" /tmp/reverify_pf.log | sed 's/^/  /'
bash /tmp/scripts/verify-barcode-preview2-v16.sh > /tmp/reverify_prev.log 2>&1
grep -E "http=|jsdelivr|dedup identical|-> 200 image/png" /tmp/reverify_prev.log | sed 's/^/  /'
bash /tmp/scripts/verify-barcode-pdf-v16.sh > /tmp/reverify_pdf.log 2>&1
grep -E "http=|pdf=" /tmp/reverify_pdf.log | sed 's/^/  /'
