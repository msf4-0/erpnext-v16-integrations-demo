#!/usr/bin/env bash
# Syntax-check the edited installer + helper, and unit-test the two new helpers
# (install_local_app_dir ownership/nesting handling; register_app_by_hand
# newline/ownership handling).
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
T=/tmp/amz-hardening
rm -rf "$T"; mkdir -p "$T"

echo "== bash -n syntax check =="
bash -n /tmp/scripts/install-app.sh && echo "  install-app.sh: OK"
bash -n /tmp/scripts/lib/common.sh && echo "  common.sh: OK"

echo
echo "== source common.sh + test install_local_app_dir =="
# shellcheck disable=SC1091
source /tmp/scripts/lib/common.sh

# build a fake source app with a nested layout (2 hooks.py? no — 1) plus .git
SRC="$T/srcapp"
mkdir -p "$SRC/pkg/pkg/doctype/thing" "$SRC/.git"
echo "app_name='x'" > "$SRC/pkg/hooks.py"
echo "{}" > "$SRC/pkg/pkg/doctype/thing/thing.json"

echo "-- case A: clean destination --"
rm -rf "$BENCH_DIR/apps/_probeA"
install_local_app_dir "_probeA" "$SRC" && echo "  placed OK"
find "$BENCH_DIR/apps/_probeA" -name hooks.py | sed 's/^/  hooks: /'
[ -d "$BENCH_DIR/apps/_probeA/.git" ] && echo "  .git PRESENT (bad)" || echo "  .git stripped OK"
rm -rf "$BENCH_DIR/apps/_probeA"

echo "-- case B: destination with ROOT-owned files (the real trap) --"
rm -rf "$BENCH_DIR/apps/_probeB"; mkdir -p "$BENCH_DIR/apps/_probeB"
echo "rootfile" > "$BENCH_DIR/apps/_probeB/old.py"
sudo chown root:root "$BENCH_DIR/apps/_probeB/old.py"
install_local_app_dir "_probeB" "$SRC" && echo "  placed OK despite root-owned dest"
find "$BENCH_DIR/apps/_probeB" -name hooks.py | sed 's/^/  hooks: /'
echo "  nested copy present? $([ -d "$BENCH_DIR/apps/_probeB/srcapp" ] && echo YES-BAD || echo no-good)"
ls -ld "$BENCH_DIR/apps/_probeB" | sed 's/^/  owner: /'
rm -rf "$BENCH_DIR/apps/_probeB"

echo "-- case C: source with TWO hooks.py (should refuse) --"
BAD="$T/badapp"; mkdir -p "$BAD/a" "$BAD/b"
echo x > "$BAD/a/hooks.py"; echo x > "$BAD/b/hooks.py"
rm -rf "$BENCH_DIR/apps/_probeC"
install_local_app_dir "_probeC" "$BAD" && echo "  UNEXPECTEDLY placed (bad)" || echo "  correctly REFUSED"
rm -rf "$BENCH_DIR/apps/_probeC"

echo
echo "== test the trailing-newline logic in isolation =="
check(){ printf '%s' "$1" > "$T/f"; [ -s "$T/f" ] && [ -z "$(tail -c1 "$T/f")" ] || printf '\n' >> "$T/f"; }
echo "-- no trailing newline --"; printf 'erpnext' > "$T/f"; { [ -s "$T/f" ] && [ -z "$(tail -c1 "$T/f")" ]; } || printf '\n' >> "$T/f"; cat "$T/f" >> "$T/f2"; od -c "$T/f" | tail -2 | sed 's/^/  /'
echo "-- already has newline --"; printf 'erpnext\n' > "$T/f"; { [ -s "$T/f" ] && [ -z "$(tail -c1 "$T/f")" ]; } || printf '\n' >> "$T/f"; od -c "$T/f" | tail -2 | sed 's/^/  /'

rm -rf "$T"
echo
echo "== done =="
