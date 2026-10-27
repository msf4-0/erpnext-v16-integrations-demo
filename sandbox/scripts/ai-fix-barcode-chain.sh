#!/usr/bin/env bash
# ai-fix-barcode-chain.sh — run the barcode_shrdc v16 fix chain correctly.
#
# `fix-barcode-v16.sh` expects its print-format fixture at
# /tmp/barcode_v16_print_formats.json, but the workspace keeps it in
# sandbox/scripts/lib/. Staged verbatim, the chain aborts on its input check
# before touching a single file (silently, from the caller's point of view) --
# which is exactly what happened on the first run.
#
# This wrapper: puts the fixture where the chain expects it, runs the chain,
# verifies the JS actually switched to the working v16 endpoint, and re-exports
# the patched tree as the durable fork.
set -uo pipefail

BENCH=/home/frappe/frappe-bench
APP="$BENCH/apps/barcode_shrdc"
JS="$APP/barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.js"
PY="$APP/barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.py"
EXPORT=/tmp/export/barcode-shrdc-v16-fixed

cd "$BENCH" || exit 1

echo "== place the print-format fixture where the chain expects it =="
if [ -f /tmp/scripts/lib/barcode_v16_print_formats.json ]; then
  cp -f /tmp/scripts/lib/barcode_v16_print_formats.json /tmp/barcode_v16_print_formats.json
elif [ -f /tmp/scripts/barcode_v16_print_formats.json ]; then
  cp -f /tmp/scripts/barcode_v16_print_formats.json /tmp/barcode_v16_print_formats.json
fi
if [ -f /tmp/barcode_v16_print_formats.json ]; then
  echo "  fixture in place ($(wc -c < /tmp/barcode_v16_print_formats.json) bytes)"
else
  echo "  ERROR: no barcode_v16_print_formats.json available"
  exit 1
fi

echo
echo "== BEFORE =="
echo "  scan_barcode refs: $(grep -c 'scan_barcode' "$JS" 2>/dev/null || echo 0)"
echo "  get_item_code refs: $(grep -c 'get_item_code' "$JS" 2>/dev/null || echo 0)"

echo
echo "== run fix-barcode-v16.sh =="
bash /tmp/scripts/fix-barcode-v16.sh
RC=$?
echo "  chain exit: $RC"

echo
echo "== AFTER =="
SB=$(grep -c 'scan_barcode' "$JS" 2>/dev/null || true)
GI=$(grep -c 'get_item_code' "$JS" 2>/dev/null || true)
echo "  scan_barcode refs: ${SB:-0}"
echo "  get_item_code refs: ${GI:-0}"
echo "  whitelist decorator on get_item_details: $(grep -c 'frappe.whitelist' "$PY" 2>/dev/null || echo 0)"
echo "  serial_no split guard: $(grep -c 'typeof' "$JS" 2>/dev/null || echo 0) 'typeof' checks"

if [ "${SB:-0}" -ge 1 ] && [ "${GI:-0}" -eq 0 ]; then
  echo "  BARCODE JS FIX: APPLIED"
else
  echo "  BARCODE JS FIX: NOT APPLIED (marker mismatch)"
fi

echo
echo "== re-export the patched tree as the durable fork =="
rm -rf "$EXPORT"
cp -a "$APP" "$EXPORT"
rm -rf "$EXPORT/.git"
find "$EXPORT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
echo "  exported $(find "$EXPORT" -type f | wc -l) files to $EXPORT"

echo
echo "== serve ping =="
curl -s -o /dev/null -w '  ping=%{http_code}\n' -H "Host: frontend" http://localhost:8000/api/method/ping
