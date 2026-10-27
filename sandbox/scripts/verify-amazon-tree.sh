#!/usr/bin/env bash
# Dump the installed amazon_integration tree to diagnose the nesting.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

echo "== apps/amazon_integration, depth 4 (dirs only) =="
find apps/amazon_integration -maxdepth 4 -type d -not -path '*/.git/*' | sort | sed 's/^/  /'

echo
echo "== every hooks.py under apps/amazon_integration =="
find apps/amazon_integration -name hooks.py -not -path '*/.git/*' | sed 's/^/  /'

echo
echo "== .git locations =="
find apps/amazon_integration -maxdepth 3 -name .git | sed 's/^/  /'

echo
echo "== apps.txt / sites/apps.txt =="
grep -n amazon apps.txt sites/apps.txt 2>/dev/null | sed 's/^/  /'

echo
echo "== what the installer copied from (/tmp/amazon-integration) =="
find /tmp/amazon-integration -maxdepth 3 -type d -not -path '*/.git/*' | sort | sed 's/^/  /'

echo
echo "== ownership of the two top dirs =="
ls -la apps/amazon_integration/ | sed 's/^/  /'
