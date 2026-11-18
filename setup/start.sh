#!/usr/bin/env bash
# comp_demo - one command from a fresh clone to a running stack (Linux/macOS).
#
# Windows users: use start.ps1 instead. This script mirrors it:
#   1. create .env from .env.example when missing
#   2. pull the prebuilt bench image (or build it as a fallback)
#   3. create containers, start db + redis, wait for healthy
#   4. run the one-shot seed service (~5-6 min)
#   5. start bench / node-red / metabase / planner, wait for /api/method/ping
#   6. run setup.ps1 when pwsh is available (planner tokens, background jobs)
#
# Usage: ./start.sh [--no-pull] [--no-wiring] [--recreate]
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NO_PULL=0
NO_WIRING=0
RECREATE=0
for arg in "$@"; do
  case "$arg" in
    --no-pull)   NO_PULL=1 ;;
    --no-wiring) NO_WIRING=1 ;;
    --recreate)  RECREATE=1 ;;
    -h|--help)   sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '  ...   %s\n' "$*"; }
ok()   { printf '  OK    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker is not installed"
docker compose version >/dev/null 2>&1 || fail "docker compose v2 is required"
docker info >/dev/null 2>&1 || fail "docker engine is not reachable - start Docker Desktop / dockerd"

[ -f docker-compose.yml ] || fail "no docker-compose.yml in $ROOT"
if [ ! -f .env ]; then
  cp .env.example .env
  ok ".env created from .env.example (no secrets needed for the local demo)"
else
  ok ".env present"
fi

env_get() {
  # last assignment wins; strips CR, surrounding quotes
  grep -E "^[[:space:]]*$1[[:space:]]*=" .env 2>/dev/null | tail -1 \
    | cut -d= -f2- | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/^"//' -e 's/"$//' || true
}

PROJECT="$(env_get COMPOSE_PROJECT_NAME)"; PROJECT="${PROJECT:-comp_demo}"
ERP_PORT="$(env_get ERPNEXT_PORT)";       ERP_PORT="${ERP_PORT:-8000}"
NR_PORT="$(env_get NODE_RED_PORT)";       NR_PORT="${NR_PORT:-1880}"
PLAN_PORT="$(env_get SCHEDULER_PORT)";    PLAN_PORT="${PLAN_PORT:-3001}"
MB_PORT="$(env_get METABASE_PORT)";       MB_PORT="${MB_PORT:-3305}"
SITE="$(env_get SITE_NAME)";              SITE="${SITE:-frontend}"
LOCAL_TAG="comp_demo-bench:v16"
GHCR_IMAGE="ghcr.io/msf4-0/comp-demo-bench:v16"
BUNDLE_URL="${BENCH_BUNDLE_URL:-https://github.com/msf4-0/erpnext-v16-integrations-demo/releases/latest/download/comp-demo-bench-v16-amd64.tar.gz}"

http_code() {
  if command -v curl >/dev/null 2>&1; then
    curl -s -o /dev/null -m "${2:-5}" -w '%{http_code}' "$1" || true
  else
    wget -q -O /dev/null --timeout="${2:-5}" "$1" >/dev/null 2>&1 && echo 200 || echo 000
  fi
}

# ---------------------------------------------------------------------------
# 1. bench image: pull first, build only as a fallback
# ---------------------------------------------------------------------------
have_image=0
docker image inspect "$LOCAL_TAG" >/dev/null 2>&1 && have_image=1

if [ "$NO_PULL" -eq 0 ] && { [ "$have_image" -eq 0 ] || [ "${FORCE_PULL:-0}" = "1" ]; }; then
  say "pulling prebuilt bench image $GHCR_IMAGE (3 GB, one time)"
  start_ts=$(date +%s)
  if docker pull --platform linux/amd64 "$GHCR_IMAGE"; then
    docker tag "$GHCR_IMAGE" "$LOCAL_TAG"
    ok "bench image pulled in $(( ($(date +%s) - start_ts) / 60 )) min"
    have_image=1
  else
    warn "GHCR pull failed (package private or no access) - trying the release bundle"
    bundle="${TMPDIR:-/tmp}/comp-demo-bench-v16-amd64.tar.gz"
    if curl -fL --retry 3 -o "$bundle" "$BUNDLE_URL"; then
      if curl -fsL -o "$bundle.sha256" "$BUNDLE_URL.sha256"; then
        expected=$(cut -d' ' -f1 "$bundle.sha256")
        actual=$(sha256sum "$bundle" | cut -d' ' -f1)
        [ "$expected" = "$actual" ] || fail "bundle checksum mismatch"
        ok "bundle checksum verified"
      else
        warn "no .sha256 published - skipping checksum"
      fi
      docker load -i "$bundle" || fail "docker load failed"
      docker image inspect "$LOCAL_TAG" >/dev/null 2>&1 || fail "bundle did not provide $LOCAL_TAG"
      ok "bench image loaded from the release bundle"
      have_image=1
      rm -f "$bundle" "$bundle.sha256"
    else
      warn "release bundle unavailable"
      warn "  permanent fix (org owner): https://github.com/organizations/msf4-0/settings/packages"
      warn "  falling back to a local build - 25-40 minutes, once"
    fi
  fi
elif [ "$have_image" -eq 1 ]; then
  ok "bench image present locally ($LOCAL_TAG)"
else
  say "skipping GHCR (--no-pull) - a local build will be used"
fi

# ---------------------------------------------------------------------------
# 2. containers
# ---------------------------------------------------------------------------
if [ "$RECREATE" -eq 1 ]; then
  say "recreating node-red and planner (volumes untouched)"
  docker compose rm -sf node-red scheduler >/dev/null 2>&1 || true
  docker compose create node-red scheduler >/dev/null
fi

already=0
[ "$(http_code "http://localhost:${ERP_PORT}/api/method/ping" 5)" = "200" ] && already=1

if [ "$already" -eq 0 ]; then
  say "docker compose create"
  docker compose --project-directory "$ROOT" create || fail "docker compose create failed - see above"

  say "starting database and redis"
  docker start "${PROJECT}-db-1" "${PROJECT}-redis-cache-1" "${PROJECT}-redis-queue-1" >/dev/null 2>&1 || true

  deadline=$(( $(date +%s) + 150 ))
  health=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 3
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${PROJECT}-db-1" 2>/dev/null || true)"
    [ "$health" = "healthy" ] && break
  done
  [ "$health" = "healthy" ] || fail "database did not become healthy (state: ${health:-unknown})"
  ok "database healthy"

  seed_state="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "${PROJECT}-seed-1" 2>/dev/null || true)"
  case "$seed_state" in
    "exited 0")
      ok "seed already completed - site data present" ;;
    *)
      say "seeding the demo database (one time, ~5-6 minutes)"
      docker start "${PROJECT}-seed-1" >/dev/null 2>&1 || true
      deadline=$(( $(date +%s) + 900 ))
      while [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 5
        seed_state="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "${PROJECT}-seed-1" 2>/dev/null || true)"
        case "$seed_state" in running*|created*|restarting*) ;; *) break ;; esac
      done
      [ "$seed_state" = "exited 0" ] || fail "seed did not finish cleanly (${seed_state:-missing}). Inspect: docker logs ${PROJECT}-seed-1"
      ok "site restored" ;;
  esac

  say "starting bench, node-red, metabase, planner"
  docker start "${PROJECT}-bench-1" "${PROJECT}-node-red-1" >/dev/null 2>&1 || true
  docker start "${PROJECT}-metabase-1" "${PROJECT}-scheduler-1" >/dev/null 2>&1 || true

  deadline=$(( $(date +%s) + 300 ))
  up=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 5
    [ "$(http_code "http://localhost:${ERP_PORT}/api/method/ping" 10)" = "200" ] && { up=1; break; }
  done

  if [ "$up" -eq 0 ]; then
    warn "ERPNext is not answering yet - restarting the bench container once"
    docker restart "${PROJECT}-bench-1" >/dev/null 2>&1 || true
    deadline=$(( $(date +%s) + 180 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      sleep 5
      [ "$(http_code "http://localhost:${ERP_PORT}/api/method/ping" 10)" = "200" ] && { up=1; break; }
    done
  fi
  [ "$up" -eq 1 ] || fail "ERPNext did not answer on :${ERP_PORT} - check: docker logs ${PROJECT}-bench-1"
fi
ok "ERPNext answers on http://localhost:${ERP_PORT}"

# ---------------------------------------------------------------------------
# 3. tokens and background jobs (needs PowerShell)
# ---------------------------------------------------------------------------
if [ "$NO_WIRING" -eq 0 ]; then
  if command -v pwsh >/dev/null 2>&1; then
    say "wiring tokens and background jobs (setup.ps1 -NonInteractive -SkipTunnel)"
    pwsh -NoProfile -File "$ROOT/setup/setup.ps1" -NonInteractive -SkipTunnel \
      || warn "setup.ps1 reported problems; the site still runs"
  else
    warn "pwsh not found - planner tokens and background jobs were not wired"
    warn "  install PowerShell 7 (https://aka.ms/powershell) and run:"
    warn "    pwsh -File ./setup.ps1 -NonInteractive -SkipTunnel"
  fi
else
  warn "skipped token wiring (--no-wiring) - the planner API will answer 401"
fi

# ---------------------------------------------------------------------------
# 4. what to do next
# ---------------------------------------------------------------------------
cat <<EOF

==========================================================================
  READY
==========================================================================
  ERPNext   http://localhost:${ERP_PORT}    Administrator / admin  (site '${SITE}')
            http://localhost:${ERP_PORT}    demo@compdemo.local / demo  (non-admin)
  Planner   http://localhost:${PLAN_PORT}
  Node-RED  http://localhost:${NR_PORT}
  Metabase  http://localhost:${MB_PORT}

  health check (read only):  pwsh -File ./setup.ps1 -VerifyOnly
  stop:                      docker compose stop
  keep data, drop containers: docker compose down        (volumes preserved)
  destroy everything:        docker compose down -v     (site data is lost)
EOF
