#!/usr/bin/env bash
# Verify create_barcode_printing with the args the app actually sends (from its
# client scripts): throw_if_missing + se_id/pr_id. Both null is a valid "create
# empty Barcode Printing" call; an empty request body is NOT how the app calls
# it, so that 500 is not a user-facing bug.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bpcbp
rm -rf "$J"; mkdir -p "$J"

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o "$J/login" -w "login=%{http_code}\n"

echo
echo "== create_barcode_printing with app-style args (throw_if_missing=true, se_id=null, pr_id=null) =="
curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.create_barcode_printing" \
  --data '{"throw_if_missing":true,"se_id":null,"pr_id":null}' \
  -o "$J/out.json" -w "  http=%{http_code}\n"
head -c 400 "$J/out.json"; echo
