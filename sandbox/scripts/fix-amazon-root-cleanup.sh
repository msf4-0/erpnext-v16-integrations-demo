#!/usr/bin/env bash
# Root-only cleanup of a botched amazon_integration install, so a clean
# install-app.sh run can follow.
#
# Root cause of the failure (banked gotcha): `docker compose cp` writes files
# into the container as ROOT. install-app.sh's local-source path runs as the
# `frappe` user and does `rm -rf apps/$APP` before `cp -r $REPO apps/$APP`.
# It could not delete the root-owned files, the rm failed partway, the
# destination still existed, and `cp -r` therefore NESTED the tree
# (apps/amazon_integration/amazon-integration/...). detect_pth_target then
# resolved the nested hooks.py and wrote a .pth pointing at the dash path, so
# `import amazon_integration` failed.
#
# Run with: docker compose -p erpnext-sandbox exec -u root bench bash -lc "bash /tmp/scripts/fix-amazon-root-cleanup.sh"
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
APP=amazon_integration

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root (-u root)"
  exit 1
fi

echo "== remove botched app dir =="
rm -rf "apps/$APP"
echo "  apps/$APP removed: $([ -d "apps/$APP" ] && echo NO || echo yes)"

echo
echo "== remove stray .pth =="
rm -f env/lib/python*/site-packages/$APP.pth
ls env/lib/python*/site-packages/$APP.pth 2>/dev/null && echo "  WARN: still present" || echo "  pth removed"

echo
echo "== unregister from app lists =="
for f in apps.txt sites/apps.txt; do
  [ -f "$f" ] || continue
  grep -vx "$APP" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
done
grep -n "$APP" apps.txt sites/apps.txt 2>/dev/null | sed 's/^/  still listed: /' || echo "  unregistered"

echo
echo "== make the staged source frappe-owned (so the next cp/rm succeed) =="
chown -R frappe:frappe /tmp/amazon-integration 2>/dev/null && echo "  chowned /tmp/amazon-integration"
ls -ld /tmp/amazon-integration | sed 's/^/  /'

echo
echo "== done (as root) =="
