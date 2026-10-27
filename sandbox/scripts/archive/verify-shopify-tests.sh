#!/usr/bin/env bash
# List shopify test files and print their bodies, so we can tell real tests
# from empty stubs. Prints a one-line verdict at the end.
set -uo pipefail
APP_DIR=/home/frappe/frappe-bench/apps/shopify

echo "== test files =="
find "$APP_DIR" -name 'test_*.py' -o -name '*_test.py' | sort

echo "== bodies =="
for f in $(find "$APP_DIR" -name 'test_*.py' -o -name '*_test.py' | sort); do
  echo "---- $f ----"
  cat "$f"
  echo
done

echo "== verdict =="
# A "real" test file has a def test_* function somewhere in it.
if grep -rlE 'def test_' "$APP_DIR" --include='test_*.py' --include='*_test.py' 2>/dev/null | grep -q .; then
  echo "REAL tests present (def test_* found) — run-tests is worth doing"
else
  echo "STUB tests only (no def test_*) — run-tests would be a no-op"
fi
