#!/usr/bin/env bash
# Dump the rendered print-format HTML for a specific doc over HTTP.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/bpdump
mkdir -p "$J"
DOC="${1:-BP-2026-09-24-00012}"

curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o /dev/null -w "login=%{http_code}\n"

for PF in "Barcode Printing Format" "QR Code Printing Format"; do
  python3 -c "import json,sys;print(json.dumps({'doc':'Barcode Printing','name':sys.argv[1],'print_format':sys.argv[2]}))" "$DOC" "$PF" > "$J/req.json"
  curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
    -X POST "$B/api/method/frappe.www.printview.get_html_and_style" \
    --data-binary @"$J/req.json" -o "$J/out.json" -w "  $PF http=%{http_code}\n"
  python3 - "$J/out.json" "$PF" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
if "exception" in d:
    print("  EXC:", d["exception"][:200]); raise SystemExit
h = ((d.get("message") or {}).get("html") or "")
print("  ---- %s (len %d) ----" % (sys.argv[2], len(h)))
print(h[:700])
PYEOF
done
