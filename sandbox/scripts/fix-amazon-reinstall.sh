#!/usr/bin/env bash
# Reinstall amazon_integration CORRECTLY after the nested-tree failure.
#
# Root cause of the failure (banked gotcha): `docker compose cp` writes files
# into the container as ROOT. install-app.sh's local-source path runs as the
# `frappe` user and does `rm -rf apps/$APP` before `cp -r $REPO apps/$APP`;
# it could not delete the root-owned doctype files, so the rm failed partway,
# the destination still existed, and `cp -r` NESTED the tree
# (apps/amazon_integration/amazon-integration/...). detect_pth_target then found
# the nested hooks.py and wrote a .pth pointing at the dash path, so the app
# could not be imported.
#
# Fix: chown the copied tree to frappe before installing. This script must run
# its root step with `-u root`.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
APP=amazon_integration

echo "== 1) (root) remove any botched app dir + stray pth =="
if [ "$(id -u)" -ne 0 ]; then
  echo "  ERROR: run this script as root (-u root) for this step"
  exit 1
fi
rm -rf "apps/$APP"
rm -f env/lib/python*/site-packages/$APP.pth
for f in apps.txt sites/apps.txt; do
  [ -f "$f" ] || continue
  grep -vx "$APP" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
echo "  removed apps/$APP and registration"

echo
echo "== 2) (root) copy the source in and hand it to frappe =="
rm -rf /tmp/amazon-integration
cp -r /tmp/amazon-integration-src "$APP" 2>/dev/null || true
if [ ! -d "apps/$APP" ]; then
  # source was staged at /tmp/amazon-integration-src by the caller
  mkdir -p "apps/$APP"
  cp -a /tmp/amazon-integration-src/. "apps/$APP/"
fi
rm -rf "apps/$APP/.git"
chown -R frappe:frappe "apps/$APP"
echo "  copied + chowned -> apps/$APP"
find "apps/$APP" -name hooks.py -not -path '*/.git/*' | sed 's/^/  hooks: /'
echo "  app tree (depth 2):"; find "apps/$APP" -maxdepth 2 -not -path '*/.git/*' | sort | sed 's/^/    /'

echo
echo "== 3) (root) write the .pth for the NESTED layout =="
# Nested layout: apps/<app>/<pkg>/hooks.py -> the OUTER package is the .pth target.
SP=$(find env/lib -maxdepth 2 -type d -name 'site-packages' | head -1)
echo "/home/frappe/frappe-bench/apps/$APP" > "$SP/$APP.pth"
echo "  $APP.pth -> /home/frappe/frappe-bench/apps/$APP"

echo
echo "== 4) hand back to frappe for the rest =="
chown -R frappe:frappe "apps/$APP" "$SP/$APP.pth"
echo "  done"
