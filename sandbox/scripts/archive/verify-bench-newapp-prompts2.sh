#!/usr/bin/env bash
# Dump the exact prompt sequence of bench's new-app wizard.
set -uo pipefail

BENCH_PKG=/home/frappe/.bench/bench

echo "== prompt/confirm in app.py =="
grep -n 'prompt\|confirm' "$BENCH_PKG/app.py" | head -40

echo
echo "== context around each prompt (show the variable + default) =="
grep -n -B2 -A6 'click.prompt\|click.confirm' "$BENCH_PKG/app.py" | head -120
