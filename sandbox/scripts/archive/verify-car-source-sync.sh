#!/usr/bin/env bash
# Prove the HOST source of truth (./repos/car-tracker, copied to
# /tmp/car-tracker-recheck) is byte-identical to the INSTALLED app in the
# container. Excludes .git/__pycache__/.frappe, which are runtime/SCM artifacts.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

diff -r \
  --exclude=.git \
  --exclude=__pycache__ \
  --exclude=.frappe \
  /tmp/car-tracker-recheck apps/car_tracker
STATUS=$?
echo "diff exit status: $STATUS"
if [ "$STATUS" -eq 0 ]; then
  echo "SOURCE-OF-TRUTH: host repo matches the installed app (no content drift)"
else
  echo "SOURCE-OF-TRUTH: DRIFT DETECTED (see above)"
fi
