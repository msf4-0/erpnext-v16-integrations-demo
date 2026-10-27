#!/usr/bin/env bash
# Clean a botched amazon_integration install (nested tree / wrong .pth) so it can
# be reinstalled. Safe + idempotent: only touches amazon_integration artifacts.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
APP=amazon_integration

echo "== before =="
ls -d apps/$APP 2>/dev/null | sed 's/^/  /'
cat env/lib/python*/site-packages/$APP.pth 2>/dev/null | sed 's/^/  pth -> /'

echo
echo "== uninstall from the site (if registered) =="
bench --site "$SITE" uninstall-app "$APP" --yes --no-backup 2>&1 | tail -5 | sed 's/^/  /' || true

echo
echo "== drop app dirs, pth, registrations =="
rm -rf apps/$APP
rm -f env/lib/python*/site-packages/$APP.pth
for f in apps.txt sites/apps.txt; do
  [ -f "$f" ] || continue
  grep -vx "$APP" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
python3 - <<'PYEOF'
import os, glob
# drop the editable install entry so a reinstall starts clean
for sp in glob.glob("/home/frappe/frappe-bench/env/lib/python*/site-packages"):
    for f in glob.glob(os.path.join(sp, "*.pth")):
        if "amazon" in os.path.basename(f).lower():
            os.remove(f)
            print("  removed", f)
PYEOF

echo
echo "== after =="
ls -d apps/$APP 2>/dev/null && echo "  WARN: app dir still present" || echo "  app dir gone"
grep -n amazon apps.txt sites/apps.txt 2>/dev/null | sed 's/^/  still registered: /' || echo "  not registered"
ls env/lib/python*/site-packages/$APP.pth 2>/dev/null && echo "  WARN: pth present" || echo "  pth gone"

echo
echo "== residual DB artifacts (if any) =="
cat > apps/barcode_shrdc/barcode_shrdc/_amzchk.py <<'PYEOF'
import frappe


def run():
    print("MARK doctype:", frappe.db.exists("DocType", "Amazon Account"))
    print("MARK module def:", frappe.db.exists("Module Def", "Amazon Integration"))
    print("MARK table:", frappe.db.sql("SHOW TABLES LIKE 'tabAmazon Account'"))
PYEOF
bench --site "$SITE" execute barcode_shrdc._amzchk.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f apps/barcode_shrdc/barcode_shrdc/_amzchk.py
