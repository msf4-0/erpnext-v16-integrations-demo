#!/usr/bin/env bash
# Print frappe's new-app prompt table (boilerplate.py) in order, so we know
# exactly how many piped answers `bench new-app` consumes.
set -uo pipefail

B=/home/frappe/frappe-bench/apps/frappe/frappe/utils/boilerplate.py

echo "== prompt config table =="
sed -n '20,100p' "$B"
