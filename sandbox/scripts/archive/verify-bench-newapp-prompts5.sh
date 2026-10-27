#!/usr/bin/env bash
# Find where the new-app wizard prompts actually live (cookiecutter
# template or a boilerplate module), since they are not in make.py/app.py.
set -uo pipefail

BENCH_PKG=/home/frappe/.bench/bench

echo "== full new_app body =="
sed -n '/^def new_app(/,/^def /p' "$BENCH_PKG/app.py" | head -80

echo
echo "== search whole bench pkg for the prompt strings =="
grep -rn "App Title\|Branch Name\|Create GitHub Workflow\|App Publisher" \
  "$BENCH_PKG" 2>/dev/null | grep -v Binary | head -20

echo
echo "== any cookiecutter / boilerplate templates =="
find "$BENCH_PKG" -iname '*cookiecutter*' -o -iname '*boilerplate*' 2>/dev/null | head
ls "$BENCH_PKG" | head -40
