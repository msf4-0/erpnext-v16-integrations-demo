#!/usr/bin/env bash
# The host ./repos/robotics_lab tree ended up with a DUPLICATE nested copy
# (my first `docker compose cp <dir> <existing-dir>` nested instead of merging;
# the second used the `/.` form and laid the correct tree at the root).
#
# Establish: (1) are the duplicates identical or divergent, and (2) would the
# mess break a future install? This matters because a stale hooks.py in the
# wrong place can break install-app.sh's detect_pth_target.
set -uo pipefail
T=/tmp/hostfork-test

echo "=== 1. CORRECT tree (what a nested-layout frappe app must look like) ==="
echo "repo root : $T"
echo "  pyproject.toml                : $([ -f "$T/pyproject.toml" ] && echo yes || echo NO)"
echo "  robotics_lab/hooks.py         : $([ -f "$T/robotics_lab/hooks.py" ] && echo yes || echo NO)"
echo "  robotics_lab/modules.txt      : $([ -f "$T/robotics_lab/modules.txt" ] && echo yes || echo NO)"
echo "  .../doctype/device/device.json: $([ -f "$T/robotics_lab/robotics_lab/doctype/device/device.json" ] && echo yes || echo NO)"

echo
echo "=== 2. Are the duplicated device files identical? ==="
A="$T/robotics_lab/robotics_lab/doctype/device"
B="$T/robotics_lab/robotics_lab/robotics_lab/doctype/device"
for f in device.json device.py device.js test_device.py __init__.py; do
  if [ -f "$A/$f" ] && [ -f "$B/$f" ]; then
    if diff -q "$A/$f" "$B/$f" >/dev/null 2>&1; then
      echo "  $f: IDENTICAL"
    else
      echo "  $f: *** DIVERGENT ***"
      diff "$A/$f" "$B/$f" | head -5
    fi
  else
    echo "  $f: missing on one side (A=$([ -f "$A/$f" ] && echo y || echo n) B=$([ -f "$B/$f" ] && echo y || echo n))"
  fi
done

echo
echo "=== 3. Would install-app.sh's detect_pth_target still resolve correctly? ==="
HP=$(find "$T" -maxdepth 3 -name 'hooks.py' 2>/dev/null | head -n1)
echo "  all hooks.py found:"
find "$T" -maxdepth 4 -name 'hooks.py' | sed "s|^$T/|    |"
echo "  first (chosen): ${HP#$T/}"
echo "  pth target    : $(dirname "$(dirname "$HP")")"
if [ "$(dirname "$(dirname "$HP")")" = "$T/robotics_lab" ]; then
  echo "  RESULT: CORRECT — pth points at the package dir, install would work"
else
  echo "  RESULT: *** BROKEN *** — pth target is wrong"
fi

echo
echo "=== 4. Does the MODULE dir contain stray package files (the merged mess)? ==="
MD="$T/robotics_lab/robotics_lab"
echo "  contents of the module dir $MD:"
ls -1 "$MD" 2>/dev/null | sed 's/^/    /'
echo "  (a clean module dir should contain: __init__.py, .frappe, doctype/, and little else)"
