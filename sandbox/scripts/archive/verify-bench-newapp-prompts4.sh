#!/usr/bin/env bash
# Dump bench/app.py::new_app so the full prompt sequence is known up front.
set -uo pipefail

BENCH_PKG=/home/frappe/.bench/bench

echo "== def new_app (with prompts) =="
awk '/^def new_app\(/,/^def [a-z_]+\(/' "$BENCH_PKG/app.py" | head -80

echo
echo "== every click.prompt/confirm in app.py with line numbers =="
grep -n 'click.prompt\|click.confirm' "$BENCH_PKG/app.py"
