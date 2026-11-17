#!/usr/bin/env bash
# Verify the permission matrix with a REAL non-System-Manager user:
#   - a user whose only relevant role is `All` must be able to READ Amazon Account
#     but NOT create/write/delete.
#   - Administrator (System Manager) can do all of it.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
J=/tmp/amzperm
rm -rf "$J"; mkdir -p "$J"
USER_EMAIL="amz-all-role@example.com"
USER_PWD="AmzTest!2345"

echo "== create the limited user (frappe core via a helper) =="
cat > apps/amazon_integration/amazon_integration/_mkuser.py <<'PYEOF'
import frappe


def run():
    email = "amz-all-role@example.com"
    if frappe.db.exists("User", email):
        print("MARK user exists already")
        return
    u = frappe.get_doc({
        "doctype": "User",
        "email": email,
        "first_name": "AmzAllRole",
        "send_welcome_email": 0,
        "enabled": 1,
        "new_password": "AmzTest!2345",
    })
    # deliberately give only roles that are NOT System Manager
    u.append("roles", {"role": "All"})
    u.insert(ignore_permissions=True)
    frappe.db.commit()
    print("MARK user created:", email)
    print("MARK roles:", [r.role for r in u.roles])
PYEOF
bench --site "$SITE" execute amazon_integration._mkuser.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f apps/amazon_integration/amazon_integration/_mkuser.py

echo
echo "== ensure one record exists (created as Administrator) =="
curl -s -c "$J/admin.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o /dev/null -w "  admin login=%{http_code}\n"
python3 -c "import json;print(json.dumps({'doctype':'Amazon Account','account_name':'PERM Amazon Account','seller_id':'PERMSELLER01'}))" > "$J/seed.json"
curl -s -b "$J/admin.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/resource/Amazon%20Account" --data-binary @"$J/seed.json" \
  -o "$J/seed.out" -w "  seed http=%{http_code}\n" || true

echo
echo "== login as the All-role user =="
curl -s -c "$J/limited.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d "{\"usr\":\"$USER_EMAIL\",\"pwd\":\"$USER_PWD\"}" "$B/api/method/login" \
  -o "$J/limitedlogin.out" -w "  limited login=%{http_code}\n"
head -c 200 "$J/limitedlogin.out"; echo

echo
echo "== limited user READ list (expect 200) =="
curl -s -b "$J/limited.jar" -H "Host: $SITE" \
  "$B/api/resource/Amazon%20Account?limit_page_length=5" -o "$J/llist.json" -w "  http=%{http_code}\n"
python3 -c "import json;d=json.load(open('$J/llist.json'));print('  rows visible:', len(d.get('data') or []))" 2>/dev/null || true

echo
echo "== limited user CREATE (expect 4xx permission error) =="
python3 -c "import json;print(json.dumps({'doctype':'Amazon Account','account_name':'PERM Should Fail','seller_id':'PERMFAIL01'}))" > "$J/lcreate.json"
curl -s -b "$J/limited.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/resource/Amazon%20Account" --data-binary @"$J/lcreate.json" \
  -o "$J/lcreate.out" -w "  http=%{http_code}\n"
head -c 200 "$J/lcreate.out"; echo

echo
echo "== limited user WRITE an existing record (expect 4xx) =="
curl -s -b "$J/limited.jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X PUT "$B/api/resource/Amazon%20Account/$(cat $J/seed.out 2>/dev/null | python3 -c 'import json,sys;print((json.load(sys.stdin).get("data") or {}).get("name","MISSING"))' 2>/dev/null)" \
  --data '{"status":"Suspended"}' -o "$J/lwrite.out" -w "  http=%{http_code}\n"
head -c 200 "$J/lwrite.out"; echo

echo
echo "== cleanup =="
cat > apps/amazon_integration/amazon_integration/_cleanup.py <<'PYEOF'
import frappe


def run():
    for n in frappe.get_all("Amazon Account", pluck="name"):
        frappe.delete_doc("Amazon Account", n, force=True, ignore_permissions=True)
    if frappe.db.exists("User", "amz-all-role@example.com"):
        frappe.delete_doc("User", "amz-all-role@example.com", force=True, ignore_permissions=True)
    frappe.db.commit()
    print("MARK remaining accounts:", frappe.db.count("Amazon Account"))
    print("MARK user gone:", not frappe.db.exists("User", "amz-all-role@example.com"))
PYEOF
bench --site "$SITE" execute amazon_integration._cleanup.run 2>&1 | grep -E '^MARK|Error' | sed 's/^/  /'
rm -f apps/amazon_integration/amazon_integration/_cleanup.py
