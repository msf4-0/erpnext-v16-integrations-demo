#!/usr/bin/env bash
# Generic app installer: runs the KNOWN-GOOD path for an app, using a
# recipe file if one exists. Does NOT do open-ended troubleshooting —
# that stays the agent's job when this script fails or no recipe exists.
#
# Requires PyYAML in the container's system python3 (frappe itself
# depends on it, so it's normally present — worth a quick `python3 -c
# "import yaml"` check if this ever errors oddly on a new base image).
#
# Usage: install-app.sh <app_name> <repo_url_or_local_dir> <erpnext_version> [recipe_yaml]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

APP="${1:?Usage: install-app.sh <app_name> <repo_url_or_local_dir> <version> [recipe_yaml]}"
REPO="${2:?repo url or local dir required}"
VERSION="${3:?erpnext version required}"
RECIPE="${4:-}"

BRANCH="" EXTRA_PIP="" VERIFY_DOCTYPE=""

# Recipe parsing must use the bench venv python, NOT bare `python3`:
# the system python in the frappe/bench image has no `yaml` module, so a
# bare `python3 -c "import yaml"` silently fails and every recipe field
# (branch, extra_pip, verify_doctype) comes back empty. The venv always
# has pyyaml because frappe depends on it.
PY="$BENCH_DIR/env/bin/python"
if [ ! -x "$PY" ]; then
  echo "ERROR: venv python not found at $PY"
  exit 1
fi

if [ -n "$RECIPE" ] && [ -f "$RECIPE" ]; then
  echo "-- Loading recipe: $RECIPE --"
  BRANCH=$("$PY" -c "
import yaml
d = yaml.safe_load(open('$RECIPE'))
v = (d.get('versions') or {}).get('$VERSION', {})
print(v.get('branch') or '')
" 2>/dev/null)
  EXTRA_PIP=$("$PY" -c "
import yaml
d = yaml.safe_load(open('$RECIPE'))
v = (d.get('versions') or {}).get('$VERSION', {})
print(' '.join(v.get('extra_pip') or []))
" 2>/dev/null)
  VERIFY_DOCTYPE=$("$PY" -c "
import yaml
d = yaml.safe_load(open('$RECIPE'))
v = (d.get('versions') or {}).get('$VERSION', {})
print(v.get('verify_doctype') or '')
" 2>/dev/null)
fi

cd "$BENCH_DIR" || exit 1

echo "== Installing $APP (branch: ${BRANCH:-default}) =="

# Register an app that is already present at apps/<APP> (no git clone).
# Shared by the local-source path and the get-app failure recovery. Also
# fixes the apps.txt trailing-newline bug: a file whose last line lacks a
# newline (e.g. 'erpnext' with no \n) would otherwise concatenate the new
# app name onto the previous line ('erpnextbarcode_shrdc'). Newer bench
# keeps the app list only in sites/apps.txt; older bench also has a root
# apps.txt — write both when present.
register_app_by_hand() {
  for f in apps.txt sites/apps.txt; do
    [ -f "$f" ] || continue
    # A `docker compose cp` can leave these root-owned; writing then fails with
    # "Permission denied" and the app looks unregistered even though it is on
    # disk. Reclaim ownership (self-heal) before writing.
    if [ ! -w "$f" ]; then
      echo "-- $f is not writable ($(id -un)); reclaiming ownership --"
      sudo chown "$(id -un):$(id -gn)" "$f" 2>/dev/null \
        || { echo "ERROR: cannot write $f"; return 1; }
    fi
    # Trailing-newline fix (else 'erpnext' + 'app' concatenate), then append.
    { [ -s "$f" ] && [ -z "$(tail -c1 "$f")" ]; } || printf '\n' >> "$f"
    grep -qx "$APP" "$f" 2>/dev/null || echo "$APP" >> "$f"
  done
}

# Local-source install: when REPO is a path to an existing directory (e.g. a
# local fork copied into the container at /tmp/<fork>), `bench get-app`
# cannot be used — it only fetches git URLs, and a fix branch that exists
# only in a local fork has no remote to fetch. Copy the directory to
# apps/<APP> and register it by hand (exactly what get-app would do minus
# the clone), then pip-install requirements.txt as get-app normally would.
if [ -d "$REPO" ]; then
  echo "-- Local source directory detected ($REPO); bypassing bench get-app --"
  # Ownership-aware, verified placement. The old inline `rm -rf; cp -r` nested
  # the tree when the destination held root-owned files (a `docker compose cp`
  # artifact) — see common.sh::install_local_app_dir and install-log entry #48.
  install_local_app_dir "$APP" "$REPO" || exit 1
  register_app_by_hand
  if [ -f "apps/$APP/requirements.txt" ]; then
    # shellcheck disable=SC1091
    source env/bin/activate
    pip install -r "apps/$APP/requirements.txt" || true
    deactivate
  fi
else
  # BENCH_DISABLE_UV=1 makes bench use pip instead of uv for dependency
  # install. uv refuses URL dependencies (e.g. the `pypika @ git+...` in
  # this app's requirements.txt) and aborts get-app mid-way; pip handles
  # them fine, so get-app completes cleanly and the recovery path below
  # becomes a fallback rather than the normal flow.
  GET_APP_OK=1
  # --overwrite makes get-app re-clone over a stale existing app directory
  # instead of aborting on "A directory for the application '...' already
  # exists" (which used to force a manual rm on a re-run). Newer bench
  # accepts it; older bench ignores unknown flags, so it's safe either way.
  GET_APP_OVERWRITE=""
  if bench get-app --help 2>&1 | grep -q -- --overwrite; then
    GET_APP_OVERWRITE="--overwrite"
  fi

  if [ -n "$BRANCH" ]; then
    BENCH_DISABLE_UV=1 bench get-app "$REPO" --branch "$BRANCH" $GET_APP_OVERWRITE || GET_APP_OK=0
  else
    BENCH_DISABLE_UV=1 bench get-app "$REPO" $GET_APP_OVERWRITE || GET_APP_OK=0
  fi

  if [ "$GET_APP_OK" -eq 0 ]; then
    if [ -d "apps/$APP" ]; then
      echo "-- get-app failed but apps/$APP was cloned (registration didn't"
      echo "   complete — e.g. uv dependency resolution aborting). Generic"
      echo "   recovery: pip install requirements.txt directly, register by hand --"
      # shellcheck disable=SC1091
      source env/bin/activate
      [ -f "apps/$APP/requirements.txt" ] && pip install -r "apps/$APP/requirements.txt"
      deactivate
      register_app_by_hand
    else
      echo "ERROR: get-app failed and apps/$APP was never created."
      echo "This needs agent troubleshooting, not this script."
      exit 1
    fi
  fi
fi

# Extra deps the generic recovery above couldn't infer (app-specific,
# from the recipe).
if [ -n "$EXTRA_PIP" ]; then
  echo "-- Installing recipe-declared extra deps: $EXTRA_PIP --"
  # shellcheck disable=SC1091
  source env/bin/activate
  pip install $EXTRA_PIP
  deactivate
fi

PTH_TARGET=$(detect_pth_target "$APP") || exit 1
SITE_PACKAGES=$(detect_site_packages) || exit 1
echo "$PTH_TARGET" > "$SITE_PACKAGES/$APP.pth"
echo "-- .pth registered: $APP.pth -> $PTH_TARGET --"

check_custom_script_fixture "$APP" "$VERSION" || echo "-- proceeding anyway; may fail below --"
filter_missing_custom_field_dts "$APP" "$VERSION"

if ! bench --site "$SITE_NAME" install-app "$APP"; then
  echo "ERROR: install-app failed. This needs agent troubleshooting."
  exit 1
fi

bench --site "$SITE_NAME" migrate

# Generic recovery for Single-doctype tables that migrate silently skips
# when a prior partial install left the modified-timestamp matching.
# Run via `bench execute` (non-interactive) rather than feeding a heredoc
# into `bench console`, which can hang waiting on stdin on a clean run.
bench --site "$SITE_NAME" execute \
  "frappe.model.sync.sync_for" \
  --kwargs "{'app_name': '$APP', 'force': 1}" 2>&1 | tail -5

restart_bench_serve
wait_for_site 60 || echo "-- site slow to respond after restart, verifying anyway --"

echo "-- Verification --"
# list-apps lines look like "barcode_shrdc 0.0.1 master" (name + version
# columns), so an exact-line grep -qx "$APP" never matches. Match the app
# name as a whole word at the start of a line instead.
if bench --site "$SITE_NAME" list-apps | grep -qE "^$APP([[:space:]]|$)"; then
  echo "OK: $APP registered"
else
  echo "FAIL: $APP not in list-apps"
fi

DOCTYPE="${VERIFY_DOCTYPE:-$(detect_verify_doctype "$APP")}"
if [ -n "$DOCTYPE" ]; then
  echo "-- Authenticated REST check against doctype: $DOCTYPE --"
  curl -s -c /tmp/cookies.txt -H "Host: $SITE_NAME" -H "Content-Type: application/json" \
    -d '{"usr":"Administrator","pwd":"admin"}' http://localhost:8000/api/method/login > /dev/null
  ENC_DOCTYPE=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$DOCTYPE'))")
  CODE=$(curl -s -b /tmp/cookies.txt -H "Host: $SITE_NAME" -o /dev/null -w "%{http_code}" \
    "http://localhost:8000/api/resource/$ENC_DOCTYPE?limit_page_length=1")
  echo "REST status for $DOCTYPE: $CODE"
else
  echo "-- No doctype found to verify against (auto-detect and recipe both empty) --"
fi

echo "== $APP install run complete — review output above, this is a report, not a guarantee =="
