#!/usr/bin/env bash
# End-to-end test of rebuild-apps.sh (the container half of the one-command
# rebuild) against the CURRENT container — no down -v, so it exercises the
# idempotent reinstall path:
#   1. reset both apps to a clean installed state
#   2. stage the sources + recipes the way the host wrapper does
#   3. run rebuild-apps.sh
#   4. assert both apps are installed, ping 200, and the key endpoints work
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend

echo "== ensure staged sources are frappe-owned =="
sudo chown -R frappe:frappe /tmp/barcode-shrdc-v16 /tmp/amazon-integration-src 2>/dev/null || true
ls -d /tmp/barcode-shrdc-v16 /tmp/amazon-integration-src | sed 's/^/  /'

echo
echo "== run rebuild-apps.sh (idempotent reinstall) =="
bash /tmp/scripts/rebuild-apps.sh > /tmp/rebuildapps.log 2>&1
echo "  rc=$?"
grep -E "####|placed app at|registered|REST status|serve up|REBUILD-APPS|ERROR" /tmp/rebuildapps.log | sed 's/^/  /'

echo
echo "== summary from the script =="
sed -n '/summary/,$p' /tmp/rebuildapps.log | sed 's/^/  /'
