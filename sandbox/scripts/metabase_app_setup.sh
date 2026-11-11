#!/bin/bash
# Runs INSIDE the bench container. Idempotent.
#   $1 = static-embedding secret from Metabase
#   $2 = Metabase base URL as the *browser* sees it (default http://localhost:3005)
set -e
SECRET="${1:?secret required}"
MBURL="${2:-http://localhost:3005}"
BB=/home/frappe/frappe-bench

# 1. put the app on the venv import path
SP=$(dirname "$(find $BB/env -name 'frappe.pth' -print -quit)")
printf '%s\n' "$BB/apps/metabase_integration" > "$SP/metabase_integration.pth"

# 2. apps.txt
cd "$BB"
grep -qx metabase_integration sites/apps.txt || echo metabase_integration >> sites/apps.txt

# 3. install on the site (no-op when already installed)
if bench --site frontend list-apps 2>/dev/null | grep -qx metabase_integration; then
  echo "app already installed"
else
  echo "installing app on site ..."
  bench --site frontend install-app metabase_integration 2>&1 | tail -4
fi

# 4. PyJWT 2.x compat: jwt.encode() returns str, the code calls token.decode()
F=$BB/apps/metabase_integration/metabase_integration/metabase_integration/doctype/metabase_dashboard/__init__.py
if grep -q "token.decode('utf8')" "$F"; then
  python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
open(p, 'w').write(s.replace(
    "token.decode('utf8')",
    "token if isinstance(token, str) else token.decode('utf8')"))
print("patched PyJWT2 compatibility")
PY
else
  echo "PyJWT2 patch already applied"
fi

# 5. settings + dashboard record + sign a token
cp /tmp/metabase_app_config.py "$BB/sites/_mb_cfg.py" 2>/dev/null || true
cd "$BB/sites"
"$BB/env/bin/python" _mb_cfg.py "$SECRET" "$MBURL" 2>/dev/null
rm -f "$BB/sites/_mb_cfg.py"
echo "done"
