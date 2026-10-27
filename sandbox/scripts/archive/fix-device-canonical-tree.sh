#!/usr/bin/env bash
# Write the CANONICAL robotics_lab app tree to the host via a single tar
# extraction (avoids the `docker compose cp <dir> <existing-dir>` nesting trap
# that left a duplicate copy on the host).
#
# The authoritative content is the WORKING install in the container plus the
# device doctype source we authored.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

APP=robotics_lab
STAGE=/tmp/canonical
rm -rf "$STAGE"
mkdir -p "$STAGE/$APP"

# --- copy the app root files (repo-level metadata) ---
for f in .editorconfig .eslintrc .gitignore .pre-commit-config.yaml \
         README.md license.txt pyproject.toml; do
  [ -f "apps/$APP/$f" ] && cp "apps/$APP/$f" "$STAGE/$APP/$f"
done

# --- copy the python package (robotics_lab/) ---
mkdir -p "$STAGE/$APP/$APP"
cp -r "apps/$APP/$APP/." "$STAGE/$APP/$APP/"
rm -rf "$STAGE/$APP/$APP/__pycache__"
find "$STAGE/$APP/$APP" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
find "$STAGE/$APP/$APP" -name '_diag' -type d -prune -exec rm -rf {} + 2>/dev/null
# the app-root metadata must NOT also sit inside the package dir
for f in pyproject.toml README.md license.txt .gitignore .eslintrc .editorconfig; do
  rm -f "$STAGE/$APP/$APP/$f"
done

echo "== canonical tree =="
find "$STAGE/$APP" -type f | sed "s|^$STAGE/||" | sort

echo
echo "== invariants (each MUST be exactly 1) =="
echo "  hooks.py     : $(find "$STAGE/$APP" -name hooks.py | wc -l)"
echo "  device.json  : $(find "$STAGE/$APP" -name device.json | wc -l)"
echo "  pyproject    : $(find "$STAGE/$APP" -name pyproject.toml | wc -l)"
echo "  no nested dup: $([ -d "$STAGE/$APP/$APP/$APP/$APP" ] && echo 'JUNK PRESENT' || echo 'ok')"

echo
echo "== tar it for a single-shot host extraction =="
tar -C "$STAGE" -cf /tmp/robotics_lab_canonical.tar "$APP"
ls -la /tmp/robotics_lab_canonical.tar
