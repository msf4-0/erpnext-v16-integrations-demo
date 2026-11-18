#!/usr/bin/env bash
# Determine whether the duplicated copy in the HOST tree would actually break
# a future install, using GROUND TRUTH:
#   1. what .pth the WORKING install currently uses
#   2. what detect_pth_target would derive from the host tree
# My earlier check compared against the wrong expected value, so redo it
# properly rather than leaving a wrong claim standing.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
T=/tmp/hostfork-test

# Source the real helper so we use the SAME logic install-app.sh uses.
source /tmp/scripts/lib/common.sh 2>/dev/null || true

echo "== 1. GROUND TRUTH: the .pth of the currently-WORKING install =="
SP=$(detect_site_packages 2>/dev/null)
echo "site-packages: $SP"
echo "robotics_lab.pth content: $(cat "$SP/robotics_lab.pth" 2>/dev/null)"
echo "(this is what a working install resolves to)"

echo
echo "== 2. detect_pth_target on the WORKING container app =="
echo "  -> $(detect_pth_target robotics_lab 2>/dev/null)"

echo
echo "== 3. detect_pth_target on the HOST tree copy =="
# Replicate detect_pth_target against the copied host tree.
HP=$(find "$T" -maxdepth 3 -name 'hooks.py' 2>/dev/null | head -n1)
echo "  first hooks.py : ${HP#$T/}"
TARGET=$(dirname "$(dirname "$HP")")
echo "  derived target : $TARGET"

echo
echo "== 4. compare: would a host-tree install land on the right target? =="
# When installed, the host tree lands at apps/robotics_lab, so replace $T.
EXPECTED="/home/frappe/frappe-bench/apps/robotics_lab"
DERIVED="${TARGET/$T/$EXPECTED}"
echo "  derived (as installed): $DERIVED"
echo "  expected              : $EXPECTED"
if [ "$DERIVED" = "$EXPECTED" ]; then
  echo "  RESULT: CORRECT — the duplicate does NOT break .pth resolution"
else
  echo "  RESULT: BROKEN"
fi

echo
echo "== 5. residual risk from the junk inside the package dir =="
echo "-- stray files in the PACKAGE dir that belong to the app ROOT:"
PKG="$T/robotics_lab"
for f in pyproject.toml README.md license.txt .gitignore .eslintrc; do
  [ -e "$PKG/$f" ] && echo "    stray: robotics_lab/$f"
done
echo "-- nested duplicate app root inside the package dir:"
[ -d "$T/robotics_lab/robotics_lab/robotics_lab" ] && echo "    robotics_lab/robotics_lab/robotics_lab/ (JUNK)"
echo "-- second hooks.py (confuses find ordering):"
find "$T" -name hooks.py | sed "s|^$T/|    |"
