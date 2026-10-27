#!/usr/bin/env bash
# Restart the dev server INSIDE the container.
# The serve process runs as `frappe serve` (NOT `bench serve`), so pkill must
# match that. A backgrounded process is killed when the exec session ends, so
# it must be detached with setsid + stdin redirected (docs/WINDOWS-QUOTING.md rule 8);
# verify reachability in a SEPARATE exec afterwards.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

pkill -f "frappe serve" 2>/dev/null
pkill -f "bench serve" 2>/dev/null
sleep 3

setsid nohup bench serve --port 8000 > /tmp/bench-serve.log 2>&1 < /dev/null &
disown

echo "launched; waiting for bind..."
sleep 10
ps aux | grep -E "frappe serve|bench serve" | grep -v grep | head -5
