#!/usr/bin/env bash
# Re-run diagnostics capturing FULL console output to a readable log.
set -uo pipefail
SITE=frontend
cd /home/frappe/frappe-bench || exit 1
bench --site "$SITE" console < /tmp/_diag.py > /tmp/diag.out 2>&1
echo "---- full diag.out ----"
cat -A /tmp/diag.out | sed -n '1,80p' | sed 's/\$$//'
echo "---- end ----"
