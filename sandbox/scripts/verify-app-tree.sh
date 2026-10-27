#!/usr/bin/env bash
# Print the AUTHORITATIVE app tree (the installed app in the container) so the
# host copy can be made to match it exactly. A double `docker compose cp` on the
# host left a nested duplicate, so this is the reference of truth.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

echo "== installed app tree: apps/robotics_lab (excluding __pycache__, .git, _diag) =="
find apps/robotics_lab \
  -path '*__pycache__*' -prune -o \
  -path '*/.git/*' -prune -o \
  -path '*_diag*' -prune -o \
  -type f -print | sed 's|^apps/robotics_lab/||' | sort

echo
echo "== staged clean tree: /tmp/final-app/robotics_lab =="
find /tmp/final-app/robotics_lab -type f | sed 's|^/tmp/final-app/robotics_lab/||' | sort

echo
echo "== where is the doctype on disk? =="
find apps/robotics_lab -name device.json

echo
echo "== all hooks.py under the app (duplicates would confuse the .pth detect) =="
find apps/robotics_lab -name hooks.py
