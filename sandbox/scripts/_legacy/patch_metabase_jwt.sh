#!/bin/bash
set -e
F=/home/frappe/frappe-bench/apps/metabase_integration/metabase_integration/metabase_integration/doctype/metabase_dashboard/__init__.py
# PyJWT 2.x returns str; the old app's `token.decode('utf8')` breaks on Python 3.
sed -i "s/token.decode('utf8')/token/" "$F"
grep -n "token" "$F"
echo "PATCHED"
