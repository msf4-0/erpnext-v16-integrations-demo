#!/usr/bin/env bash
# Run the amazon_integration test suite.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend

echo "== allow_tests =="
bench --site "$SITE" set-config allow_tests true && echo "  allow_tests set"

echo
echo "== run-tests --app amazon_integration =="
bench --site "$SITE" run-tests --app amazon_integration 2>&1 | tail -40 | sed 's/^/  /'
