#!/usr/bin/env bash
# `bench new-app` delegates to frappe's `make-app`. Find that command and its
# prompt sequence so every answer can be piped non-interactively.
set -uo pipefail

FRAPPE=/home/frappe/frappe-bench/apps/frappe

echo "== files defining make-app / boilerplate =="
grep -rln "make-app\|make_app" "$FRAPPE/frappe/commands" 2>/dev/null | head
ls "$FRAPPE/frappe/utils/boilerplate.py" 2>/dev/null

echo
echo "== App Title prompt source =="
grep -rn "App Title" "$FRAPPE/frappe" --include=*.py 2>/dev/null | head

echo
echo "== click.prompt/confirm in boilerplate =="
if [ -f "$FRAPPE/frappe/utils/boilerplate.py" ]; then
  grep -n "click.prompt\|click.confirm\|prompt =\|confirm =" "$FRAPPE/frappe/utils/boilerplate.py" | head -40
fi
