#!/usr/bin/env bash
# Generate a canonical v16 Frappe app scaffold for car_tracker using
# bench new-app, so the boilerplate (pyproject.toml, .gitignore, hooks.py,
# patches.txt, modules.txt) matches exactly what v16 expects rather than
# being hand-guessed. Runs INSIDE the bench container; the result is copied
# back to the host as the source of truth.
#
# Usage: fix-new-app-car-tracker.sh <output_dir_inside_container>
set -uo pipefail

APP="car_tracker"
OUT="${1:-/tmp/car-tracker-scaffold}"
cd /home/frappe/frappe-bench || exit 1

rm -rf "apps/$APP" "$OUT"

echo "== bench new-app $APP (non-interactive) =="
# Answers, in the exact order frappe's boilerplate wizard asks (see
# frappe/utils/boilerplate.py::_get_user_inputs — 7 prompts):
#   1 app_title  2 app_description  3 app_publisher  4 app_email
#   5 app_license  6 create_github_workflow  7 branch_name
# Running out of piped answers ABORTS the wizard, so all 7 must be supplied.
# NOTE: v16 validates the license against a lowercase SPDX choice list and
# aborts on 'MIT' — it must be lowercase 'mit'.
printf '%s\n' \
  "Car Tracker" \
  "Track cars with basic details, service history, mileage and maintenance dates." \
  "Car Tracker" \
  "admin@example.com" \
  "mit" \
  "N" \
  "version-16" \
  | bench new-app "$APP" 2>&1 | tail -20

if [ ! -d "apps/$APP" ]; then
  echo "ERROR: apps/$APP was not created"
  exit 1
fi

echo "== generated tree =="
find "apps/$APP" -type f | sort

mkdir -p "$OUT"
cp -r "apps/$APP/." "$OUT/"
rm -rf "$OUT/.git"
echo "== scaffold copied to $OUT =="
