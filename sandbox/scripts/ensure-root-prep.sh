#!/usr/bin/env bash
# Root-only prep that MUST run before provision-base.sh on a fresh
# `down -v` + `up`. Two things require root and live outside the frappe
# user's control:
#
#   1. The bench_sites volume mount point /home/frappe/frappe-bench is
#      created as ROOT on a fresh volume. The frappe user cannot chown it,
#      and `bench init` dies with PermissionError if it isn't owned by
#      frappe. (provision-base.sh detects this and tells you to run this.)
#   2. redis-server must exist in the bench container's writable layer
#      (wiped if the container is recreated). The base image may or may
#      not have it; install it if missing.
#
# Run as root, e.g.:
#
#   docker compose -p erpnext-sandbox cp ./sandbox/scripts/ensure-root-prep.sh \
#     bench:/tmp/scripts/ensure-root-prep.sh
#   docker compose -p erpnext-sandbox exec -u root bench bash -lc \
#     "chmod +x /tmp/scripts/ensure-root-prep.sh && /tmp/scripts/ensure-root-prep.sh"
#
# Idempotent: safe to re-run on an already-prepared bench.

set -uo pipefail

BENCH_DIR="/home/frappe/frappe-bench"

echo "== root-prep: ensure bench dir is frappe-owned =="
if [ -d "$BENCH_DIR" ]; then
  chown -R frappe:frappe "$BENCH_DIR"
  echo "  chowned $BENCH_DIR -> frappe:frappe"
else
  echo "  $BENCH_DIR does not exist yet; nothing to chown (created on first run)"
fi

echo "== root-prep: ensure redis-server is present =="
if command -v redis-server >/dev/null 2>&1; then
  echo "  redis-server already present"
else
  echo "  redis-server not found — installing (needs network)"
  apt-get update -qq && apt-get install -y -qq redis-server
  echo "  installed redis-server"
fi

echo "== root-prep done =="
