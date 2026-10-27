#!/usr/bin/env bash
# Stage the FINAL robotics_lab app tree in the container so it can be copied
# back to the host as the source of truth. Excludes the throwaway _diag
# verification helpers and __pycache__ — those are test scaffolding, not app
# source.
set -uo pipefail
APP=robotics_lab
cd /home/frappe/frappe-bench || exit 1

STAGE=/tmp/final-app
rm -rf "$STAGE"
mkdir -p "$STAGE"

# Copy the app, then prune non-source artifacts.
cp -r "apps/$APP" "$STAGE/$APP"
rm -rf "$STAGE/$APP/.git"
find "$STAGE/$APP" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
# _diag can land at either depth depending on how it was created — prune any.
find "$STAGE/$APP" -name '_diag' -type d -prune -exec rm -rf {} + 2>/dev/null

echo "== final source tree =="
find "$STAGE/$APP" -type f | sed "s|$STAGE/||" | sort

echo
echo "== confirm the Device doctype files are present =="
ls -la "$STAGE/$APP/$APP/$APP/doctype/device/"

echo
echo "== confirm _diag is gone =="
if [ -d "$STAGE/$APP/$APP/_diag" ]; then echo "STILL PRESENT (bad)"; else echo "pruned OK"; fi
