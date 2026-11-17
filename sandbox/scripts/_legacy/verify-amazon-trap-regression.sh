#!/usr/bin/env bash
# Reproduce the ORIGINAL nesting trap against the HARDENED installer:
#   1. plant a root-owned apps/amazon_integration (what `docker compose cp` did)
#   2. plant a root-owned sites/apps.txt line + non-writable registry file
#   3. run install-app.sh and confirm it self-heals (no nesting, app imports)
# Read the result; this is the regression proof for the entry-#48 fix.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
J=/tmp/amz-trap
rm -rf "$J"; mkdir -p "$J"

echo "== 1) plant a ROOT-owned, partially-populated apps/amazon_integration =="
sudo rm -rf apps/amazon_integration
sudo mkdir -p apps/amazon_integration/amazon_integration/doctype/amazon_account
sudo tee apps/amazon_integration/amazon_integration/doctype/amazon_account/old_root_owned.json >/dev/null <<'EOF'
{"leftover": true}
EOF
sudo chown -R root:root apps/amazon_integration
ls -ld apps/amazon_integration | sed 's/^/  /'
echo "  (this is exactly the state that made the old rm -rf fail partway)"

echo
echo "== 2) plant a root-owned sites/apps.txt (the old Permission-denied case) =="
echo "amazon_integration" >> sites/apps.txt
sudo chown root:root sites/apps.txt
ls -l sites/apps.txt | sed 's/^/  /'

echo
echo "== 3) run the HARDENED install-app.sh =="
/tmp/scripts/install-app.sh amazon_integration /tmp/amazon-integration-src 16 /tmp/recipes/amazon_integration.yaml > "$J/install.log" 2>&1
echo "  rc=$?"
grep -E "Local source|not writable|reclaiming|placed app at|hooks.py|registered|REST status|ERROR|nest" "$J/install.log" | sed 's/^/  /'

echo
echo "== 4) assert the tree is NOT nested and there is exactly ONE hooks.py =="
find apps/amazon_integration -name hooks.py -not -path '*/.git/*' | sed 's/^/  hooks: /'
echo "  count: $(find apps/amazon_integration -name hooks.py | wc -l | tr -d ' ')"
echo "  nested dir (apps/amazon_integration/amazon-integration)? $([ -d apps/amazon_integration/amazon-integration ] && echo YES-BAD || echo no-good)"
echo "  leftover old json still there? $([ -f apps/amazon_integration/amazon_integration/doctype/amazon_account/old_root_owned.json ] && echo YES-BAD || echo no-good)"

echo
echo "== 5) .pth + import + list-apps =="
cat env/lib/python*/site-packages/amazon_integration.pth | sed 's/^/  pth -> /'
ls -l sites/apps.txt | sed 's/^/  apps.txt owner: /'
bench --site "$SITE" list-apps | sed 's/^/  /'
