#!/usr/bin/env bash
# Verify the batch preview renders when a batch_no is actually present.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bpprev3
mkdir -p "$J"

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o /dev/null -w "login=%{http_code}\n"

cat > "$J/batch.json" <<'JSONEOF'
{"doc":{"name":"BP-2026-09-24-00001","batch_barcode_type":"CODE128","items":[{"item_code":"SKU010","item_name":"Camera","qty":1,"rate":9.5,"batch_no":"BATCH-DEMO-01"}]},"kind":"batch"}
JSONEOF
curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_preview_html" \
  --data-binary @"$J/batch.json" -o "$J/batch.out.json" -w "  batch http=%{http_code}\n"
python3 - "$J/batch.out.json" <<'PYEOF'
import json, re, sys
d = json.load(open(sys.argv[1]))
if "exception" in d:
    print("  EXCEPTION:", d["exception"][:200]); raise SystemExit
h = d.get("message") or ""
print("  len=%d imgs=%d jsdelivr=%s svg=%s" % (len(h), h.count("<img"), "jsdelivr" in h, "<svg" in h))
print("  urls:", sorted(set(re.findall(r'/files/[A-Za-z0-9_.\-]+', h))))
print("  contains item_code:", "SKU010" in h, "| contains batch text:", "BATCH-DEMO-01" in h)
PYEOF
