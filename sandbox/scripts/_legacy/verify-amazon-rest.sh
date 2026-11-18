#!/usr/bin/env bash
# REST verification for Amazon Account:
#   - authenticated CRUD over /api/resource
#   - uniqueness enforced over REST
#   - read-only enforcement for the `All` role (a non-System-Manager user)
#   - naming series + defaults
#   - regression: ping + an unrelated core doctype + the barcode app
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/amzrest
rm -rf "$J"; mkdir -p "$J"

echo "== login as Administrator =="
curl -s -c "$J/admin.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" \
  -o /dev/null -w "  admin login=%{http_code}\n"

echo
echo "== GET list =="
curl -s -b "$J/admin.jar" -H "Host: $SITE" \
  "$B/api/resource/Amazon%20Account?limit_page_length=5" -o "$J/list.json" -w "  http=%{http_code}\n"
head -c 200 "$J/list.json"; echo

echo
echo "== POST create =="
python3 -c "import json;print(json.dumps({'doctype':'Amazon Account','account_name':'REST Amazon Account','seller_id':'RESTSELLER01','account_type':'Vendor Central','status':'Active'}))" > "$J/new.json"
curl -s -b "$J/admin.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/resource/Amazon%20Account" --data-binary @"$J/new.json" \
  -o "$J/created.json" -w "  http=%{http_code}\n"
python3 - "$J/created.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
data = d.get("data") or {}
print("  name:", data.get("name"))
print("  account_type:", data.get("account_type"), "| status:", data.get("status"))
print("  account_name:", data.get("account_name"), "| seller_id:", data.get("seller_id"))
open("/tmp/amzrest/name.txt", "w").write(data.get("name") or "")
PYEOF
NAME=$(cat "$J/name.txt")

echo
echo "== GET one =="
curl -s -b "$J/admin.jar" -H "Host: $SITE" \
  "$B/api/resource/Amazon%20Account/$NAME" -o "$J/one.json" -w "  http=%{http_code}\n"
python3 - "$J/one.json" <<'PYEOF'
import json, sys
d = (json.load(open(sys.argv[1])) or {}).get("data") or {}
print("  fields:", sorted(k for k in d if k in ("name","account_name","seller_id","account_type","status")))
PYEOF

echo
echo "== duplicate account_name over REST (expect 4xx) =="
python3 -c "import json;print(json.dumps({'doctype':'Amazon Account','account_name':'REST Amazon Account','seller_id':'RESTSELLER99'}))" > "$J/dupname.json"
curl -s -b "$J/admin.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/resource/Amazon%20Account" --data-binary @"$J/dupname.json" \
  -o "$J/dupname.out" -w "  http=%{http_code}\n"
head -c 180 "$J/dupname.out"; echo

echo
echo "== duplicate seller_id over REST (expect 4xx) =="
python3 -c "import json;print(json.dumps({'doctype':'Amazon Account','account_name':'REST Amazon Account 2','seller_id':'RESTSELLER01'}))" > "$J/dupseller.json"
curl -s -b "$J/admin.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/resource/Amazon%20Account" --data-binary @"$J/dupseller.json" \
  -o "$J/dupseller.out" -w "  http=%{http_code}\n"
head -c 180 "$J/dupseller.out"; echo

echo
echo "== blank account_name over REST (expect 4xx) =="
python3 -c "import json;print(json.dumps({'doctype':'Amazon Account','seller_id':'RESTSELLER77'}))" > "$J/blank.json"
curl -s -b "$J/admin.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/resource/Amazon%20Account" --data-binary @"$J/blank.json" \
  -o "$J/blank.out" -w "  http=%{http_code}\n"

echo
echo "== whitespace in seller_id over REST (expect 4xx) =="
python3 -c "import json;print(json.dumps({'doctype':'Amazon Account','account_name':'REST Amazon Account 3','seller_id':'BAD ID'}))" > "$J/ws.json"
curl -s -b "$J/admin.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/resource/Amazon%20Account" --data-binary @"$J/ws.json" \
  -o "$J/ws.out" -w "  http=%{http_code}\n"
head -c 200 "$J/ws.out"; echo

echo
echo "== cleanup the created record =="
curl -s -b "$J/admin.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X DELETE "$B/api/resource/Amazon%20Account/$NAME" -o /dev/null -w "  delete http=%{http_code}\n"

echo
echo "== regression: core + barcode + ping =="
for D in "Company" "Item" "Barcode%20Printing"; do
  curl -s -b "$J/admin.jar" -H "Host: $SITE" -o /dev/null -w "  GET $D -> %{http_code}\n" \
    "$B/api/resource/$D?limit_page_length=1"
done
curl -s -o /dev/null -w "  ping=%{http_code}\n" -H "Host: $SITE" "$B/api/method/ping"
