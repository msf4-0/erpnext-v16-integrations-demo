#!/usr/bin/env bash
# Find the new-app wizard's prompt strings so every answer can be piped.
set -uo pipefail

BENCH_PKG=/home/frappe/.bench/bench

echo "== where do 'App Title' / 'Branch Name' come from =="
grep -rn "App Title" "$BENCH_PKG" 2>/dev/null | head
grep -rn "Branch Name" "$BENCH_PKG" 2>/dev/null | head

echo
echo "== def new_app in make.py =="
grep -n -A40 "def new_app" "$BENCH_PKG/commands/make.py" | head -60
