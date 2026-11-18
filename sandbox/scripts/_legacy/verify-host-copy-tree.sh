#!/usr/bin/env bash
# Inspect the HOST copy of ./repos/robotics_lab as it was copied into the
# container, to establish whether the host tree is correct or duplicated.
# A duplicated hooks.py would break install-app.sh's detect_pth_target on a
# future reinstall, so this matters.
set -uo pipefail
T=/tmp/hostfork-test

echo "== full host-copied tree =="
find "$T" -type f | sed "s|^$T/||" | sort

echo
echo "== hooks.py files found (should be exactly ONE) =="
find "$T" -name hooks.py | sed "s|^$T/||"
echo "count: $(find "$T" -name hooks.py | wc -l)"

echo
echo "== device.json files found (should be exactly ONE) =="
find "$T" -name device.json | sed "s|^$T/||"
echo "count: $(find "$T" -name device.json | wc -l)"

echo
echo "== pyproject.toml found (should be exactly ONE, at the repo root) =="
find "$T" -name pyproject.toml | sed "s|^$T/||"

echo
echo "== is this a valid nested-layout frappe app? =="
if [ -f "$T/pyproject.toml" ] && [ -f "$T/robotics_lab/hooks.py" ] \
   && [ -f "$T/robotics_lab/robotics_lab/doctype/device/device.json" ]; then
  echo "YES: root pyproject.toml + robotics_lab/hooks.py + robotics_lab/robotics_lab/doctype/device/"
else
  echo "NO — tree shape is wrong"
fi

echo
echo "== what install-app.sh's detect_pth_target would pick =="
HP=$(find "$T" -maxdepth 3 -name 'hooks.py' | head -n1)
echo "first hooks.py: ${HP#$T/}"
echo "pth target would be: $(dirname "$(dirname "$HP")")"
