#!/usr/bin/env bash
# barcode_shrdc on ERPNext v16 — ONE-SHOT fix for the Barcode Printing form and
# its print formats. App-specific (do NOT move into lib/common.sh).
#
# Run this AFTER the app is installed and after the ROOT-only render-deps step
# (fix-barcode-v16-renderdeps.sh) has been done once per container.
#
# Covers every error reproduced in this run (see verify-barcode-newdoc-v16.sh):
#   1. class-method get_item_details not whitelisted (403 on item select)
#   2. module-level get_item_details 500 (invalid SQL / AttributeError)
#   3. "Create QR" on an unsaved doc -> 404 DoesNotExistError
#   4. save crash: TypeError item.serial_no.split is not a function
#   5. dead v16 JS APIs (erpnext.setup_serial_no, SerialNoBatchSelector,
#      non-whitelisted get_item_code)
#   6. blank/plain print formats (CDN JsBarcode <svg>, data-URI QR, resize CSS)
#   7. on-form "Preview:" sections blank (client-side JsBarcode from a CDN)
#   8. print/PDF preview HostNotFoundError (unresolvable get_url host)
#
# Idempotent: each underlying step is marker-based, so re-running is safe.
#
# Inputs expected (copy in first):
#   /tmp/scripts/fix-barcode-v16-py.sh
#   /tmp/scripts/fix-barcode-v16-js.sh
#   /tmp/scripts/fix-barcode-v16-preview.sh
#   /tmp/scripts/fix-barcode-v16-printformats.sh
#   /tmp/barcode_v16_print_formats.json        (== lib/barcode_v16_print_formats.json)
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

APP=/home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc
PY="$APP/barcode_shrdc/doctype/barcode_printing/barcode_printing.py"
JS="$APP/barcode_shrdc/doctype/barcode_printing/barcode_printing.js"
SITE=frontend

for f in /tmp/scripts/fix-barcode-v16-py.sh /tmp/scripts/fix-barcode-v16-js.sh \
         /tmp/scripts/fix-barcode-v16-preview.sh /tmp/scripts/fix-barcode-v16-printformats.sh \
         /tmp/barcode_v16_print_formats.json; do
  if [ ! -f "$f" ]; then echo "ERROR: missing input $f"; exit 1; fi
done

echo "########## 1/7  Python controller ##########"
bash /tmp/scripts/fix-barcode-v16-py.sh

echo
echo "########## 2/7  form JS ##########"
bash /tmp/scripts/fix-barcode-v16-js.sh

echo
echo "########## 3/7  on-form Preview sections (server-side) ##########"
bash /tmp/scripts/fix-barcode-v16-preview.sh

echo
echo "########## 4/7  print formats + jinja hook ##########"
bash /tmp/scripts/fix-barcode-v16-printformats.sh

echo
echo "########## 5/7  print/PDF preview hostname ##########"
bash /tmp/scripts/fix-barcode-v16-hostname.sh

echo
echo "########## 6/7  cleanup helper modules from the app tree ##########"
# pf_sync_helper.py / pf_seed_helper.py are only used to drive `bench execute`
# from the verify scripts (bench console mangles multi-line loops). They are not
# part of the app and must not ship.
rm -f "$APP/pf_sync_helper.py" "$APP/pf_seed_helper.py"
ls "$APP"/*helper*.py 2>/dev/null && echo "  WARN: helper modules still present" || echo "  helper modules removed"

echo
echo "########## 7/7  bump doctype modified, clear cache, restart serve ##########"
# Editing a doctype's .py/.js does NOT bump the DocType `modified`, so the desk
# keeps serving a stale cached form. Bump it explicitly.
cat > "$APP/_bump_modified.py" <<'PYEOF'
import frappe


def run():
	now = frappe.utils.now()
	for dt in ("Barcode Printing", "Barcode Generator Items"):
		if frappe.db.exists("DocType", dt):
			frappe.db.set_value("DocType", dt, "modified", now)
			print("MARK bumped", dt)
	frappe.db.commit()
	frappe.clear_cache()
	print("MARK cache cleared")
PYEOF
bench --site "$SITE" execute barcode_shrdc._bump_modified.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f "$APP/_bump_modified.py"
env/bin/python -c "import os,sys,glob; [os.remove(p) for p in glob.glob('$APP/**/__pycache__/barcode_printing*.pyc', recursive=True)]" 2>/dev/null || true

pkill -f 'frappe serve' 2>/dev/null || true
pkill -f 'bench serve' 2>/dev/null || true
sleep 3
( cd /home/frappe/frappe-bench && setsid nohup bench serve --port 8000 > /tmp/bench-serve.log 2>&1 < /dev/null & disown )
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SITE" http://localhost:8000/api/method/ping || true)
  [ "$code" = "200" ] && { echo "  serve up after ${i}s (ping 200)"; break; }
  sleep 1
done

echo
echo "== $0 complete — run verify-barcode-newdoc-v16.sh,"
echo "   verify-barcode-printformats-v16.sh, verify-barcode-preview2-v16.sh and"
echo "   verify-barcode-pdf-v16.sh to confirm =="
