#!/usr/bin/env bash
# Generic base ERPNext provisioning, parameterized by version.
#
# Redis needs root to install and lives in the writable layer (wiped if
# the service container is recreated) — run that check separately as
# root BEFORE this script, which should run as the normal bench user:
#
#   docker compose -p erpnext-sandbox exec -u root bench bash -lc \
#     "which redis-server || (apt-get update -qq && apt-get install -y -qq redis-server)"
#   docker compose -p erpnext-sandbox exec bench bash -lc \
#     "/tmp/scripts/provision-base.sh <version>"
#
# Usage: provision-base.sh <erpnext_version>   e.g. provision-base.sh 16

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

VERSION="${1:?Usage: provision-base.sh <erpnext_version>}"
BRANCH="version-$VERSION"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-admin}"
ERPNEXT_ADMIN_PASSWORD="${ERPNEXT_ADMIN_PASSWORD:-admin}"

echo "== Provisioning ERPNext v$VERSION base =="

# Fail fast on a wrong base image / DB charset BEFORE any long work. A
# stale compose (e.g. bench :latest with the wrong Python, or mariadb
# without utf8mb4) previously broke mid-way with confusing errors.
if ! check_base_requirements "$VERSION"; then
  echo "ERROR: base requirements for v$VERSION not met — fix compose/image and re-run."
  exit 1
fi

# Legacy ERPNext needs an older Python than the image's default (the
# frappe/bench:version-12 image defaults to 3.10, but v12 requires 3.7).
# Prefer the image's explicit PYTHON_VERSION_V<N> env var when present,
# else fall back to whatever `python3` is on PATH. Passed to `bench init
# --python` so the venv is created against the right interpreter.
PY_VAR="PYTHON_VERSION_V$VERSION"
if [ -n "${!PY_VAR:-}" ]; then
  PY_EXEC="/home/frappe/.pyenv/versions/${!PY_VAR}/bin/python"
  if [ -x "$PY_EXEC" ]; then
    echo "-- Using $PY_EXEC for bench init (v$VERSION needs ${!PY_VAR}) --"
    PY_INIT_ARGS=(--python "$PY_EXEC")
  else
    echo "-- PYTHON_VERSION_V$VERSION=${!PY_VAR} set but $PY_EXEC missing; using default python3 --"
    PY_INIT_ARGS=()
  fi
else
  PY_INIT_ARGS=()
fi

cd /home/frappe || exit 1

# A fresh `down -v` + `up` recreates the bench_sites volume, and the
# volume mount point /home/frappe/frappe-bench is created as ROOT. The
# frappe user (this script's identity) cannot chown it, so `bench init`
# dies with PermissionError on 'frappe-bench/apps'. This script runs as
# the non-root frappe user and CANNOT fix it — the caller must chown as
# root first (see module-installer.md Step 0.4). Detect and fail clearly
# rather than letting bench init die mid-way.
if [ -d "$BENCH_DIR" ] && [ "$(stat -c '%U' "$BENCH_DIR")" != "frappe" ]; then
  echo "ERROR: $BENCH_DIR is owned by '$(stat -c '%U' "$BENCH_DIR")', not 'frappe'."
  echo "A fresh volume mount is root-owned. Run this as root first:"
  echo "  docker compose -p erpnext-sandbox exec -u root bench bash -lc \"chown -R frappe:frappe $BENCH_DIR\""
  exit 1
fi

# The bench image (comp_demo-bench:v16) already ships a fully initialised bench
# tree (env/ + apps/frappe + apps/erpnext + the custom apps). Re-running
# `bench init` over it is not only wasted work (~2-5 min of uv/yarn/build), it
# is BROKEN in bench v5: with --ignore-exist and a RELATIVE path, bench
# re-installs frappe from "frappe-bench/apps/frappe" while it is already
# chdir'ed into frappe-bench, so uv exits 2 with
# "Distribution not found at: file:///home/frappe/frappe-bench/frappe-bench/apps/frappe".
# bench then asks "Do you want to rollback these changes?" on stdin - and under
# `docker compose exec -T` that prompt is invisible to the caller, so up.ps1
# sat there at 0% CPU forever instead of failing.
# Hence: only init when the existing tree is genuinely unusable, always pass an
# ABSOLUTE path, bound the runtime, and give bench /dev/null as stdin so any
# prompt aborts immediately instead of hanging.
BENCH_READY=0
if [ -d "$BENCH_DIR/apps/frappe" ] && "$BENCH_DIR/env/bin/python" -c 'import frappe' >/dev/null 2>&1; then
  BENCH_READY=1
  echo "-- Reusing the bench already present at $BENCH_DIR (frappe $("$BENCH_DIR/env/bin/python" -c 'import frappe; print(frappe.__version__)' 2>/dev/null)) --"
fi

if [ "$BENCH_READY" -ne 1 ]; then
  # Only pay for a recursive chown when the tree actually needs initialising:
  # the baked bench is already frappe-owned, and `chown -R` over venv/ +
  # node_modules costs minutes on this host's slow container-storage path.
  chown -R frappe:frappe "$BENCH_DIR" 2>/dev/null || true
  echo "-- Initialising bench at $BENCH_DIR (absolute path, 30 min cap, stdin closed) --"
  if ! timeout 1800 bench init --frappe-branch "$BRANCH" --ignore-exist "${PY_INIT_ARGS[@]}" "$BENCH_DIR" < /dev/null; then
    echo "ERROR: bench init failed or timed out - see the output above."
    echo "  Re-run after fixing the cause; the venv/ and apps/ tree may be partial."
    exit 1
  fi
fi

cd "$BENCH_DIR" || exit 1

# Yarn on this host repeatedly times out against registry.yarnpkg.com
# (ESOCKETTIMEDOUT fetching a tarball), which makes `bench get-app erpnext`
# abort mid-install. Set the yarn knobs IN the container as a belt-and-
# suspenders to the compose env vars: the env vars may not reach every nested
# `yarn install` (e.g. erpnext's own `cd banking && yarn install` postinstall),
# while ~/.yarnrc applies to every yarn invocation for the rest of this run.
yarn config set network-timeout 600000 >/dev/null 2>&1 || true
yarn config set network-concurrency 1 >/dev/null 2>&1 || true
yarn config set fetch-retries 5 >/dev/null 2>&1 || true
yarn config set fetch-retry-maxtimeout 120000 >/dev/null 2>&1 || true
echo "-- yarn network settings: timeout=$(yarn config get network-timeout)ms concurrency=$(yarn config get network-concurrency) retries=$(yarn config get fetch-retries) --"

# bench get-app can fail on a transient network error (e.g. git clone
# "RPC failed; curl 56 GnuTLS recv error" / "fatal: early EOF"). If we
# don't stop here, `new-site --install-app erpnext` runs with no erpnext
# module and half-provisions a frappe-only site that reports "SUCCESS" at
# the end. Fail fast and clearly so the operator retries (the clone is
# idempotent) instead of silently proceeding without ERPNext.
GET_APP_OK=0
# The bench image already contains apps/erpnext installed into the venv, so a
# git clone + uv install + asset build here costs minutes and fetches nothing
# new. Only fetch when the tree is actually missing/unusable. (stdin is closed
# for the same reason as bench init above: no invisible prompts.)
if "$BENCH_DIR/env/bin/python" -c 'import erpnext' >/dev/null 2>&1; then
  echo "-- apps/erpnext already present and importable; skipping get-app --"
  GET_APP_OK=1
fi

for attempt in 1 2 3; do
  [ "$GET_APP_OK" -eq 1 ] && break
  echo "-- bench get-app erpnext --branch $BRANCH (attempt $attempt/3) --"
  if timeout 1800 bench get-app erpnext --branch "$BRANCH" < /dev/null; then
    GET_APP_OK=1
    break
  fi
  echo "-- get-app attempt $attempt failed; retrying in 10s --"
  sleep 10
done
if [ "$GET_APP_OK" -ne 1 ]; then
  echo "ERROR: bench get-app erpnext failed after 3 attempts (transient git/network error)."
  echo "  Provisioning aborted — the ERPNext source was NOT fully cloned."
  echo "  Fix connectivity and re-run provision-base.sh $VERSION (get-app is idempotent)."
  exit 1
fi
if [ ! -d "apps/erpnext" ]; then
  echo "ERROR: get-app erpnext reported success but apps/erpnext does not exist."
  exit 1
fi

# db_host defaults to 127.0.0.1; point at the compose service names instead.
bench set-config -g db_host db
bench set-config -g db_port 3306
bench set-config -g redis_cache redis://redis-cache:6379
bench set-config -g redis_queue redis://redis-queue:6379

# `bench set-config -g db_port 3306` writes the port as a STRING ("3306"),
# but legacy ERPNext (v12) ships an old pymysql (0.9.3) whose connection
# code does `"socket %s:%d" % (host, port)` — a string port crashes with
# "TypeError: %d format: a number is required, not str". Force it to an int.
if [ "$VERSION" -le 13 ] 2>/dev/null; then
  echo "-- v$VERSION: coercing db_port to an integer in common_site_config.json --"
  "$BENCH_DIR/env/bin/python" - <<'PYEOF'
import json, os
p = "/home/frappe/frappe-bench/sites/common_site_config.json"
if os.path.exists(p):
    d = json.load(open(p))
    if "db_port" in d:
        d["db_port"] = int(d["db_port"])
    json.dump(d, open(p, "w"), indent=1)
    print("db_port ->", d["db_port"])
PYEOF
fi

# The bench CLI renamed new-site's DB root flags over time: older bench
# used --db-root-password/--db-root-username, newer v5 bench uses
# --mariadb-root-password/--mariadb-root-username. Detect which the
# installed bench accepts instead of hardcoding one and getting
# "no such option" on the other.
if bench new-site --help 2>&1 | grep -q -- --mariadb-root-password; then
  ROOT_PW_FLAG="--mariadb-root-password"
  ROOT_USER_FLAG="--mariadb-root-username"
else
  ROOT_PW_FLAG="--db-root-password"
  ROOT_USER_FLAG="--db-root-username"
fi

SITE_DIR="$BENCH_DIR/sites/$SITE_NAME"
# A normal up.ps1 run recreates the bench CONTAINER but keeps the bench_sites
# and db_data volumes, so the site is usually already there. `bench new-site`
# on an existing site fails, and the --force retry below then DROPS the site
# and replays the entire erpnext migration (3-5 min of pure waste, and it
# destroys any data the operator put on the site). Only build when missing.
if [ -f "$SITE_DIR/site_config.json" ] \
   && bench --site "$SITE_NAME" list-apps 2>/dev/null | grep -q '^erpnext'; then
  echo "-- site $SITE_NAME already exists with erpnext installed - reusing it --"
  echo "   (rebuild from scratch with: up.ps1 -Fresh, or setup.ps1 -Full -Wipe)"
else
  if ! bench new-site "$SITE_NAME" --admin-password "$ERPNEXT_ADMIN_PASSWORD" \
        "$ROOT_PW_FLAG" "$DB_ROOT_PASSWORD" "$ROOT_USER_FLAG" root --install-app erpnext; then
    echo "-- new-site failed (likely partial DB setup from a prior attempt),"
    echo "   retrying with --force --"
    bench new-site "$SITE_NAME" --force --admin-password "$ERPNEXT_ADMIN_PASSWORD" \
        "$ROOT_PW_FLAG" "$DB_ROOT_PASSWORD" "$ROOT_USER_FLAG" root --install-app erpnext
  fi
fi

# Serve regardless of host header (a site named e.g. 'frontend' otherwise
# rejects requests to localhost).
bench set-config -g default_site "$SITE_NAME"

restart_bench_serve

if wait_for_site 120; then
  echo "== Base v$VERSION provisioned and responding =="
else
  echo "== Base provisioned but not responding within timeout —"
  echo "   check /tmp/bench-serve.log inside the container =="
  exit 1
fi

echo "-- Verification --"
bench --site "$SITE_NAME" list-apps
bench version
