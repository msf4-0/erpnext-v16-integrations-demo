#!/usr/bin/env bash
# Bump the DocType `modified` timestamp and clear caches the CORRECT way.
# `bench execute frappe.db.set_value --kwargs {...}` does NOT work: bench
# resolves the dotted path to frappe.db.set_value (the Database method, whose
# signature is set_value(doctype, docname, fieldname, value) with NO doctype
# kwarg) -> TypeError. Use a small helper module instead.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

mkdir -p apps/robotics_lab/robotics_lab/_diag
touch apps/robotics_lab/robotics_lab/_diag/__init__.py
cat > apps/robotics_lab/robotics_lab/_diag/bump.py <<'PYEOF'
import frappe


def run():
	frappe.set_user("Administrator")
	now = frappe.utils.now()
	frappe.db.set_value("DocType", "Device", "modified", now, update_modified=False)
	frappe.db.commit()
	print("Device DocType modified ->", now)

	# Clear the doctype meta + general caches so the desk refetches.
	frappe.clear_cache(doctype="Device")
	frappe.clear_cache()
	print("caches cleared")

	# Confirm persisted.
	print("re-read:", frappe.db.get_value("DocType", "Device", "modified"))
PYEOF
bench --site "$SITE" execute robotics_lab._diag.bump.run

echo
echo "== confirm the served meta/JS reflects the new code =="
curl -s -c /tmp/b.txt -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' http://localhost:8000/api/method/login > /dev/null
curl -s -b /tmp/b.txt -H "Host: $SITE" \
  "http://localhost:8000/api/method/frappe.desk.form.load.getdoctype?doctype=Device" \
  -o /tmp/b.json -w "getdoctype HTTP %{http_code}\n"
python3 - <<'PY'
import json
m = json.load(open("/tmp/b.json"))["docs"][0]
js = m.get("__js") or ""
print("  modified in meta:", m.get("modified"))
for needle in ("voltage_v(frm)", "current_a(frm)", "check_power_consistency"):
    print(f"  [{'OK ' if needle in js else 'MISS'}] {needle}")
PY
