#!/usr/bin/env bash
# Dump the v16 SerialBatchPackageSelector constructor + scan_barcode JS usage,
# so the barcode app's JS can be adapted correctly.
set -uo pipefail
E=/home/frappe/frappe-bench/apps/erpnext/erpnext
S="$E/public/js/utils/serial_no_batch_selector.js"

echo "== serial_no_batch_selector.js: class + constructor =="
grep -n "class SerialBatchPackageSelector" -A 45 "$S" | sed 's/^/  /'

echo
echo "== serial_no_batch_selector.js: what it sets back on the row =="
grep -n "serial_and_batch_bundle\|use_serial_batch_fields\|callback\|avg_rate" "$S" | head -20 | sed 's/^/  /'

echo
echo "== stock_entry.js scan_barcode handler (v16 pattern) =="
sed -n '1410,1460p' "$E/stock/doctype/stock_entry/stock_entry.js" | sed 's/^/  /'

echo
echo "== barcode_scanner.js: which method it calls =="
grep -rn "scan_barcode" "$E/public/js" 2>/dev/null | head | sed 's/^/  /'
