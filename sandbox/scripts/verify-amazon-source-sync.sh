#!/usr/bin/env bash
# Source-of-truth integrity: diff the HOST repo (staged at /tmp/amz-host-check)
# against the INSTALLED app, excluding .git and __pycache__.
set -uo pipefail
HOST=/tmp/amz-host-check
INST=/home/frappe/frappe-bench/apps/amazon_integration

if [ ! -d "$HOST" ]; then
  echo "ERROR: stage the host repo first:"
  echo "  docker compose -p erpnext-sandbox cp ./repos/amazon-integration bench:$HOST"
  exit 1
fi

echo "== host tree =="
find "$HOST" -type f -not -path '*/.git/*' -not -path '*__pycache__*' \
  -not -path '*/node_modules/*' | sed "s|$HOST/||" | sort | sed 's/^/  /'

echo
echo "== installed tree =="
find "$INST" -type f -not -path '*/.git/*' -not -path '*__pycache__*' \
  -not -path '*/node_modules/*' -not -path '*/public/dist/*' | sed "s|$INST/||" | sort | sed 's/^/  /'

echo
echo "== diff (content) =="
diff -r -x '.git' -x '__pycache__' -x 'node_modules' -x 'dist' "$HOST" "$INST" \
  && echo "  IDENTICAL — source of truth matches the installed app"

echo
echo "== the 7 authored files, md5 (host vs installed) =="
for f in \
  amazon_integration/modules.txt \
  amazon_integration/hooks.py \
  amazon_integration/amazon_integration/doctype/__init__.py \
  amazon_integration/amazon_integration/doctype/amazon_account/__init__.py \
  amazon_integration/amazon_integration/doctype/amazon_account/amazon_account.json \
  amazon_integration/amazon_integration/doctype/amazon_account/amazon_account.py \
  amazon_integration/amazon_integration/doctype/amazon_account/test_amazon_account.py ; do
  h=$(md5sum "$HOST/$f" 2>/dev/null | cut -d' ' -f1)
  i=$(md5sum "$INST/$f" 2>/dev/null | cut -d' ' -f1)
  [ "$h" = "$i" ] && status=OK || status=DIFFERS
  printf "  %-6s %s\n" "$status" "$f"
done
