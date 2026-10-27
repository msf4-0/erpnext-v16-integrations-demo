#!/usr/bin/env bash
# Bump the Barcode Printing DocType modified + clear cache + restart serve.
# Used after a source edit when you are NOT running the full fix-barcode-v16.sh.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
APP=apps/barcode_shrdc/barcode_shrdc

cat > "$APP/_bump.py" <<'PYEOF'
import frappe


def run():
    now = frappe.utils.now()
    for dt in ("Barcode Printing", "Barcode Generator Items"):
        if frappe.db.exists("DocType", dt):
            frappe.db.set_value("DocType", dt, "modified", now)
    frappe.db.commit()
    frappe.clear_cache()
    print("MARK bumped + cache cleared")
PYEOF
bench --site "$SITE" execute barcode_shrdc._bump.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f "$APP/_bump.py"

pkill -f 'frappe serve' 2>/dev/null || true
pkill -f 'bench serve' 2>/dev/null || true
sleep 3
( cd /home/frappe/frappe-bench && setsid nohup bench serve --port 8000 > /tmp/bench-serve.log 2>&1 < /dev/null & disown )
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SITE" http://localhost:8000/api/method/ping || true)
  [ "$code" = "200" ] && { echo "  serve up after ${i}s (ping 200)"; exit 0; }
  sleep 1
done
echo "  serve did not come up in 30s"; exit 1
