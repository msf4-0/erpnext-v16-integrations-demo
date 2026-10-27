#!/usr/bin/env bash
# Confirm get_preview_html still works after the rebuild (independent of the
# hardcoded-doc-name bug in verify-barcode-preview2-v16.sh).
set -uo pipefail
B=http://localhost:8000
SITE=frontend
J=/tmp/ppchk
mkdir -p "$J"

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o /dev/null -w "login=%{http_code}\n"

python3 - "$J/sku.json" <<'PYEOF'
import json, sys
json.dump({"doc": {"name": "x", "serial_barcode_type": "CODE128", "batch_barcode_type": "CODE128",
                   "items": [{"item_code": "SKU010", "item_name": "Camera", "qty": 1, "rate": 9.5,
                              "barcode": "123456789012", "barcode_type": "EAN13"}]}, "kind": "sku"},
          open(sys.argv[1], "w"))
PYEOF

curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_preview_html" \
  --data-binary @"$J/sku.json" -o "$J/out.json" -w "preview http=%{http_code}\n"

python3 - "$J/out.json" <<'PYEOF'
import json, sys, re
d = json.load(open(sys.argv[1]))
h = d.get("message") or ""
print("  imgs:", h.count("<img"), "| jsdelivr:", "jsdelivr" in h)
print("  urls:", sorted(set(re.findall(r'/files/[A-Za-z0-9_.\-]+', h))))
PYEOF
