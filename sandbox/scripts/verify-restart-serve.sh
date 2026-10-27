#!/usr/bin/env bash
# Restart the frappe serve process in the bench container.
# The serve process is `frappe serve` (NOT `bench serve`), so pkill on
# 'bench serve' alone does not match it.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
pkill -f 'frappe serve' 2>/dev/null || true
pkill -f 'bench serve' 2>/dev/null || true
sleep 3
setsid nohup bench serve --port 8000 > /tmp/bench-serve.log 2>&1 < /dev/null &
disown
echo "serve restart issued; waiting for it to come up"
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: frontend' http://localhost:8000/api/method/ping || true)
  if [ "$code" = "200" ]; then echo "serve up after ${i}s (ping 200)"; exit 0; fi
  sleep 1
done
echo "serve did NOT come up in 30s; tail of log:"
tail -n 40 /tmp/bench-serve.log
exit 1
