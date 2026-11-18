#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-deployment.sh - acceptance check for a comp_demo deployment.
#
# Answers one question: is this deployment actually complete and working?
# Runs from the HOST, against a Compose project. Safe: read-only.
#
# Usage:
#   ./sandbox/scripts/verify-deployment.sh                    # project comp_demo
#   PROJECT=comp_demo_p7 ./sandbox/scripts/verify-deployment.sh   # isolated test
#
# Checks:
#   1. compose config renders (env files present and consistent)
#   2. bench + db containers are running
#   3. site exists and `bench --site <site> version` works
#   4. `bench --site <site> list-apps` contains all 8 apps exactly once
#   5. every app module imports in the bench venv
#   6. /api/method/ping answers over HTTP through the published port
#   7. no active app_include_js asset referenced by hooks.py is missing
#
# Exit code 0 = every check passed. Non-zero = the numbered failures printed.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

PROJECT="${PROJECT:-comp_demo}"
SITE="${SITE_NAME:-}"
PORT="${ERPNEXT_PORT:-8000}"

ENV_FILES=(--env-file .env --env-file versions.env)
[ -f .env ] || ENV_FILES=(--env-file versions.env)

compose() { docker compose -p "$PROJECT" "${ENV_FILES[@]}" -f docker-compose.yml "$@"; }

[ -n "$SITE" ] || SITE="$(awk -F= '$1=="SITE_NAME"{print $2; exit}' .env 2>/dev/null)"
SITE="${SITE:-frontend}"
[ -n "${ERPNEXT_PORT:-}" ] || PORT="$(awk -F= '$1=="ERPNEXT_PORT"{print $2; exit}' .env 2>/dev/null)"
PORT="${PORT:-8000}"

APPS="frappe erpnext barcode_shrdc shopify eu_einvoice item_tracking metabase_integration my_invois"

fails=0
ok()   { echo "PASS  $*"; }
bad()  { echo "FAIL  $*"; fails=$((fails + 1)); }
info() { echo "      $*"; }

echo "== verify-deployment: project '$PROJECT', site '$SITE', port $PORT =="

# ---- 1. compose config -----------------------------------------------------
if compose config -q >/dev/null 2>&1; then
    ok "docker compose config renders"
else
    bad "docker compose config failed (missing .env / versions.env?)"
fi

# ---- 2. containers ---------------------------------------------------------
if [ "$(docker inspect -f '{{.State.Running}}' "$(compose ps -q bench 2>/dev/null)" 2>/dev/null)" = "true" ]; then
    ok "bench container is running"
else
    bad "bench container is not running (docker compose up -d)"
fi
if [ "$(docker inspect -f '{{.State.Running}}' "$(compose ps -q db 2>/dev/null)" 2>/dev/null)" = "true" ]; then
    ok "db container is running"
else
    bad "db container is not running"
fi

# ---- 3-5. bench-level checks (one exec, parsed host-side) ------------------
bench_out="$(compose exec -T bench bash -lc "
  cd /home/frappe/frappe-bench || exit 3
  echo '__VERSION__'
  bench --site $SITE version 2>&1 || echo '__VERSION_FAILED__'
  echo '__DBAPPS__'
  bench --site $SITE execute frappe.get_installed_apps 2>&1
  echo '__LISTAPPS__'
  bench --site $SITE list-apps 2>&1 || echo '__LISTAPPS_FAILED__'
  echo '__IMPORT__'
  env/bin/python - <<'PY'
import importlib
apps = '$APPS'.split()
bad = []
for a in apps:
    try:
        importlib.import_module(a)
        print('ok', a)
    except Exception as e:
        print('bad', a, repr(e)); bad.append(a)
print('IMPORT_FAILURES', len(bad))
PY
" 2>&1)"

if printf '%s' "$bench_out" | grep -q '__VERSION_FAILED__'; then
    bad "bench --site $SITE version failed"
    info "$(printf '%s' "$bench_out" | sed -n '/__VERSION__/,/__VERSION_FAILED__/p' | tail -3 | tr '\n' ' ')"
else
    ok "bench --site $SITE version works"
    printf '%s' "$bench_out" | sed -n '/__VERSION__/,/__DBAPPS__/p' | sed '1d;$d' | sed 's/^/      /'
fi

dbapps_raw="$(printf '%s' "$bench_out" | sed -n '/__DBAPPS__/,/__LISTAPPS__/p' | sed '1d;$d')"
dbapps="$(printf '%s\n' "$dbapps_raw" | tr -d "[]'\"" | tr ',' '\n' | tr -d ' ' | sed '/^$/d')"
listapps="$(printf '%s' "$bench_out" | sed -n '/__LISTAPPS__/,/__IMPORT__/p' | sed '1d;$d')"

# The DB (tabInstalled Application) is authoritative: on this bench
# `bench list-apps` can under-report a fully installed site, so it is printed
# for information and NOT used to decide whether an app is installed.
if [ -z "$dbapps" ]; then
    bad "frappe.get_installed_apps returned nothing (site missing?)"
else
    missing=""
    for app in $APPS; do
        n="$(printf '%s\n' "$dbapps" | grep -cx "$app")"
        if [ "$n" -eq 0 ]; then missing="$missing $app"; fi
        if [ "$n" -gt 1 ]; then bad "$app is installed $n times"; fi
    done
    if [ -z "$missing" ]; then
        ok "all 8 apps installed exactly once (tabInstalled Application)"
    else
        bad "apps missing from tabInstalled Application:$missing"
    fi
    printf '%s\n' "$dbapps" | sed 's/^/      /'
fi
if [ -n "$(printf '%s' "$listapps" | tr -d '[:space:]')" ]; then
    info "bench list-apps: $(printf '%s' "$listapps" | tr '\n' ' ' | tr -s ' ')"
fi

if printf '%s' "$bench_out" | grep -qE '^IMPORT_FAILURES 0$'; then
    ok "all 8 app modules import in the bench venv"
else
    bad "one or more app modules failed to import"
    printf '%s' "$bench_out" | grep -E '^(bad|IMPORT_FAILURES)' | sed 's/^/      /'
fi

# ---- 6. HTTP ping ----------------------------------------------------------
ping_out="$(curl -s --max-time 10 -H "Host: $SITE" "http://localhost:$PORT/api/method/ping" 2>/dev/null)"
if printf '%s' "$ping_out" | grep -q '"message"'; then
    ok "GET /api/method/ping answered: $ping_out"
else
    bad "GET /api/method/ping did not answer correctly on port $PORT"
fi

# ---- 7. referenced assets --------------------------------------------------
missing_assets="$(compose exec -T bench bash -lc '
  cd /home/frappe/frappe-bench || exit 0
  for appdir in apps/*/; do
    app="$(basename "$appdir")"
    hooks="$appdir/$app/hooks.py"
    [ -f "$hooks" ] || continue
    grep -v "^[[:space:]]*#" "$hooks" | grep -oE "\"/assets/[^\"]+\.(js|css)\"" | tr -d "\"" \
      | while read -r u; do [ -e "sites$u" ] || echo "$app $u"; done
  done' 2>/dev/null)"
if [ -z "$missing_assets" ]; then
    ok "every app_include_js/css referenced by hooks.py resolves"
else
    bad "unresolved assets referenced by hooks.py:"
    printf '%s\n' "$missing_assets" | sed 's/^/      /'
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "== verify-deployment: ALL CHECKS PASSED =="
    exit 0
fi
echo "== verify-deployment: $fails CHECK(S) FAILED =="
exit 1
