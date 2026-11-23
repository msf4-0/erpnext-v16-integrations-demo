#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Git Bash / Cygwin (MSYS) rewrites every argument that looks like a POSIX
# path. That silently turns the in-CONTAINER paths below into Windows paths:
#   docker compose exec -T bench mkdir -p /tmp/comp-demo-bootstrap/lib
# really ran `mkdir -p C:/Users/<user>/AppData/Local/Temp/comp-demo-bootstrap/lib`
# inside the container (exit 0, wrong place), so the next
#   docker cp provision-base.sh <container>:/tmp/comp-demo-bootstrap/
# died with "no such directory". Every absolute path in this script is a path
# inside the container/image, so conversion must be off for the whole run.
if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
  export MSYS_NO_PATHCONV=1
  export MSYS2_ARG_CONV_EXCL='*'
fi

if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: ./up-linux.sh

Builds the bench image, restores the demo site and starts the whole stack
(ERPNext, Metabase, Node-RED, the production planner, the webhook sink) with
the seven apps installed. Select the target with COMPOSE_PROJECT_NAME /
ERPNEXT_PORT / SITE_NAME / BENCH_IMAGE in .env.

This launcher does not configure Shopify credentials or the ngrok tunnel.
HELP
  exit 0
fi
if (( $# > 0 )); then
  echo "ERROR: this launcher takes no options; use --help for details." >&2
  exit 2
fi

for tool in docker curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool is required." >&2
    exit 1
  fi
done
docker compose version >/dev/null
docker info >/dev/null

# Python 3 runs sandbox/scripts/validate-env.py. `command -v python3` is NOT
# enough on Windows: the Microsoft Store ships an App Execution Alias named
# python3 that sits on PATH but fails (or opens the Store) when executed, so the
# preflight passed and the launcher then died on a confusing traceback. Probe
# by executing, accept python as a fallback, and require 3.9+ (validate-env
# uses builtin generics like dict[str, str] in annotations).
PYTHON=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 \
     && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3, 9) else 1)' >/dev/null 2>&1; then
    PYTHON="$candidate"
    break
  fi
done
if [ -z "$PYTHON" ]; then
  echo "ERROR: a working Python 3.9+ is required (it validates .env)." >&2
  echo "       On Windows the 'python3' Microsoft Store alias does not count -" >&2
  echo "       install Python from https://python.org and re-run this script." >&2
  exit 1
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
  echo "Created .env. Set your passwords, then run ./up-linux.sh again."
  exit 1
fi
[[ -f versions.env ]] || { echo "ERROR: versions.env is missing." >&2; exit 1; }

"$PYTHON" sandbox/scripts/validate-env.py --env-file .env

env_value() {
  awk -F= -v key="$1" '
    /^[[:space:]]*#/ || !index($0, "=") { next }
    $1 == key { sub(/^[^=]*=/, ""); sub(/\r$/, ""); print; exit }
  ' "$2"
}

SITE_NAME="$(env_value SITE_NAME .env)"
SITE_NAME="${SITE_NAME:-frontend}"
ERPNEXT_PORT="$(env_value ERPNEXT_PORT .env)"
ERPNEXT_PORT="${ERPNEXT_PORT:-8000}"
FRAPPE_SERIES="$(env_value FRAPPE_SERIES versions.env)"
[[ "$FRAPPE_SERIES" =~ ^[0-9]+$ ]] || {
  echo "ERROR: FRAPPE_SERIES must be set in versions.env." >&2
  exit 1
}

# The project name comes from .env so a clone can be deployed NEXT TO an
# existing stack. It used to be hard-coded to `comp_demo`, which made the
# documented Linux command aim a clone at the live demo project (its
# containers and its named volumes) - the exact collision the isolated-test
# rule in docs/DEPLOY.md section 10 warns about.
PROJECT="$(env_value COMPOSE_PROJECT_NAME .env)"
PROJECT="${PROJECT:-comp_demo}"

compose() {
  docker compose -p "$PROJECT" --env-file .env --env-file versions.env \
    -f docker-compose.yml "$@"
}

echo "Project '$PROJECT': building the bench image (25-40 min on a cold machine)..."
compose build bench

# node-red bind-mounts sandbox/node-red/flows.json as a FILE. The built flow is
# gitignored (it embeds a real API token), so a fresh clone has no such file and
# Docker creates a DIRECTORY at the mount source. node-red then refuses to
# start: "error mounting .../flows.json ... not a directory". Materialise a
# valid empty flow so the bridge container comes up; the Shopify flow itself is
# built separately once credentials exist (sandbox/node-red/build-flows.py).
FLOWS_FILE="sandbox/node-red/flows.json"
if [[ ! -f "$FLOWS_FILE" ]]; then
  rm -rf "$FLOWS_FILE"
  printf '[]\n' > "$FLOWS_FILE"
  echo "node-red: created $FLOWS_FILE (empty flow; Shopify wiring needs credentials)"
fi

# WHY NOT `docker compose up -d`: on this host Docker Desktop attaches agent
# hooks to the `up` subcommand and it never returns, leaving containers in
# `Created`. `create` returns immediately and `docker start` takes ~15 s, so
# the two steps are split (same fix as setup/up.ps1 step 3).
echo "Creating the containers..."
compose create

echo "Starting MariaDB and Redis..."
docker start "${PROJECT}-db-1" "${PROJECT}-redis-cache-1" "${PROJECT}-redis-queue-1" >/dev/null 2>&1 || true

echo "Waiting for MariaDB (a first boot initialises the datadir: up to ~10 min on a slow disk)..."
db_ready=false
for _ in $(seq 1 200); do
  db_state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "${PROJECT}-db-1" 2>/dev/null || true)"
  if [[ "$db_state" == "healthy" ]]; then
    db_ready=true
    break
  fi
  sleep 3
done
if [[ "$db_ready" != true ]]; then
  echo "ERROR: MariaDB did not become healthy (state: ${db_state:-unknown})." >&2
  exit 1
fi

# The one-shot seeder restores seed/frontend-database.sql.gz (+ the Metabase
# metadata) the first time and exits 0. On a later run it exits immediately
# because the site already exists, so waiting for `exited 0` is safe.
seed_state="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "${PROJECT}-seed-1" 2>/dev/null || true)"
if [[ "$seed_state" == "exited 0" ]]; then
  echo "Demo site already restored (seed exited 0) - nothing to do."
else
  echo "Restoring the demo site (one-shot seed, ~5-7 min on an SSD, 30+ min on an HDD)..."
  docker start "${PROJECT}-seed-1" >/dev/null 2>&1 || true
  # 15 min aborted a seed that was still making progress on an HDD-backed host;
  # the seed has its own failure exits, so a long wait only costs time.
  seed_deadline=$((SECONDS + 3600))
  while (( SECONDS < seed_deadline )); do
    seed_state="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "${PROJECT}-seed-1" 2>/dev/null || true)"
    case "$seed_state" in
      running*|created*|restarting*) sleep 5 ;;
      *) break ;;
    esac
  done
  if [[ "$seed_state" == running* ]]; then
    echo "ERROR: seed is still running after 60 min - it has not failed; rerun this script to keep waiting." >&2
    exit 1
  fi
  if [[ "$seed_state" != "exited 0" ]]; then
    echo "ERROR: seed did not finish cleanly (state: ${seed_state:-missing})." >&2
    docker logs --tail 40 "${PROJECT}-seed-1" >&2 2>&1 || true
    exit 1
  fi
  echo "Demo site restored."
fi

# Every documented endpoint has to come up, not just ERPNext: Metabase backs
# the /metabase page, node-red ships the Shopify bridge, scheduler is the
# planner and webhook-sink is the tunnel-free receiver.
echo "Starting ERPNext, Metabase, Node-RED, planner and webhook sink..."
docker start "${PROJECT}-bench-1" "${PROJECT}-metabase-1" "${PROJECT}-node-red-1" \
  "${PROJECT}-scheduler-1" "${PROJECT}-webhook-sink-1" >/dev/null 2>&1 || true

bench_ready=false
for _ in $(seq 1 60); do
  if compose exec -T bench true >/dev/null 2>&1; then
    bench_ready=true
    break
  fi
  sleep 2
done
if [[ "$bench_ready" != true ]]; then
  echo "ERROR: the bench container did not become reachable." >&2
  exit 1
fi

echo "Provisioning or reusing ERPNext site '$SITE_NAME'..."
compose exec -T -u root bench mkdir -p /tmp/comp-demo-bootstrap/lib
docker cp sandbox/scripts/provision-base.sh "${PROJECT}-bench-1:/tmp/comp-demo-bootstrap/"
docker cp sandbox/scripts/lib/common.sh "${PROJECT}-bench-1:/tmp/comp-demo-bootstrap/lib/"
compose exec -T -u root bench chown -R frappe:frappe /tmp/comp-demo-bootstrap

compose exec -T bench bash /tmp/comp-demo-bootstrap/provision-base.sh "$FRAPPE_SERIES"

# P7: install all seven apps with the SAME installer the image bakes in, so a
# fresh Linux deployment is one command. Idempotent: on an already-complete
# site this only prints the app list and exits 0.
echo "Installing all comp_demo apps on site '$SITE_NAME'..."
compose exec -T -e "SITE_NAME=$SITE_NAME" -e "SKIP_APPS=${SKIP_APPS:-}" bench \
  bash /usr/local/bin/install-all-apps.sh

# The running web process began before a new site existed. Restart it to load
# the default-site setting written by provision-base.sh.
compose restart bench

site_url="http://localhost:${ERPNEXT_PORT}/api/method/ping"
echo "Waiting for ERPNext at http://localhost:${ERPNEXT_PORT}..."
for _ in $(seq 1 80); do
  if curl --fail --silent --show-error --max-time 5 \
    -H "Host: $SITE_NAME" "$site_url" >/dev/null 2>&1; then
    compose exec -T bench bench --site "$SITE_NAME" list-apps
    echo
    echo "ERPNext is ready at http://localhost:${ERPNEXT_PORT} (site: $SITE_NAME, project: $PROJECT)."
    echo "Planner, Metabase, Node-RED and the webhook sink are up on the ports in .env."
    echo "Verify with: PROJECT=$PROJECT ERPNEXT_PORT=$ERPNEXT_PORT SITE_NAME=$SITE_NAME bash ./sandbox/scripts/verify-deployment.sh"
    exit 0
  fi
  sleep 3
done

echo "ERROR: ERPNext did not answer its ping endpoint. Check: docker compose -p $PROJECT logs bench" >&2
exit 1
