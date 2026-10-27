#!/usr/bin/env bash
# Introspect bench's new-app wizard so we can supply ALL prompts
# non-interactively. Running out of piped answers aborts the wizard
# (observed: license -> gh-action -> branch-name -> Aborted!).
set -uo pipefail

echo "== locate bench package =="
python3 -c "import bench, os; print(os.path.dirname(bench.__file__))" 2>&1

BENCH_PKG=$(python3 -c "import bench, os; print(os.path.dirname(bench.__file__))" 2>/dev/null)
echo "BENCH_PKG=$BENCH_PKG"

if [ -n "$BENCH_PKG" ]; then
  echo "== files mentioning new_app =="
  grep -rln 'new_app' "$BENCH_PKG" 2>/dev/null | head

  echo "== prompt/confirm calls in new_app =="
  NEWAPP="$BENCH_PKG/bench/commands/make.py"
  if [ -f "$NEWAPP" ]; then
    grep -n 'prompt\|confirm\|def new_app' "$NEWAPP" | head -40
  else
    find "$BENCH_PKG" -name 'make.py' -o -name 'new_app.py' 2>/dev/null | head
  fi
fi
