#!/usr/bin/env bash
# After editing a doctype's .js/.json, the DocType `modified` timestamp is NOT
# bumped automatically, so the desk keeps serving the cached version. Bump
# `modified` for the touched doctypes, clear caches, and restart serve.
# NOTE: `bench execute frappe.db.set_value` does NOT work (it resolves to
# Database.set_value whose signature has no doctype kwarg) — use a helper
# module called via `bench execute` instead.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1

APP_DIR=apps/car_tracker/car_tracker
mkdir -p "$APP_DIR/_bump"
cat > "$APP_DIR/_bump/__init__.py" <<'PYEOF'
PYEOF
cat > "$APP_DIR/_bump/run.py" <<'PYEOF'
import frappe
from frappe.utils import now


def bump():
	frappe.set_user("Administrator")
	for doctype in ("Car", "Car Service Record", "Car Workshop"):
		frappe.db.set_value("DocType", doctype, "modified", now())
		frappe.clear_cache(doctype=doctype)
		print("bumped modified + cleared cache:", doctype)
	frappe.db.commit()
PYEOF

bench --site "$SITE" execute car_tracker._bump.run.bump
rm -rf "$APP_DIR/_bump"

echo "-- site-wide clear-cache --"
bench --site "$SITE" clear-cache 2>&1 | tail -3
