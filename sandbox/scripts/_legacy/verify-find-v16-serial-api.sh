#!/usr/bin/env bash
# Find v16 replacements for the dead erpnext JS/asset APIs the barcode app uses.
set -uo pipefail
E=/home/frappe/frappe-bench/apps/erpnext/erpnext
echo "== SerialBatchPackageSelector references (file list) =="
grep -rln "SerialBatchPackageSelector" "$E" 2>/dev/null | grep -v node_modules | head -20
echo
echo "== SerialNoBatchSelector references =="
grep -rln "SerialNoBatchSelector" "$E" 2>/dev/null | grep -v node_modules | head -20
echo
echo "== setup_serial_no references =="
grep -rln "setup_serial_no" "$E" 2>/dev/null | grep -v node_modules | head -20
echo
echo "== serial selector asset files =="
find "$E/public" -iname "*serial*batch*selector*" 2>/dev/null | head
find "$E/public" -iname "*batch*serial*" 2>/dev/null | head
echo
echo "== erpnext.stock.select_batch_and_serial_no definition =="
grep -rn "select_batch_and_serial_no" "$E/public" 2>/dev/null | head -20
echo
echo "== SerialBatchPackageSelector class file head =="
F=$(grep -rln "class SerialBatchPackageSelector" "$E" 2>/dev/null | grep -v node_modules | head -1)
echo "file: $F"
if [ -n "$F" ]; then grep -n "class SerialBatchPackageSelector" -A 40 "$F" | head -60; fi
