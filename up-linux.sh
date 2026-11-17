#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: ./up-linux.sh

Builds and provisions the core ERPNext site using Docker Compose. This
lightweight launcher does not install the custom apps or configure the
planner, Metabase, Node-RED, Shopify, or ngrok integrations.
HELP
  exit 0
fi
if (( $# > 0 )); then
  echo "ERROR: this launcher takes no options; use --help for details." >&2
  exit 2
fi

for tool in docker python3 curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool is required." >&2
    exit 1
  fi
done
docker compose version >/dev/null
docker info >/dev/null

if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
  echo "Created .env. Set your passwords, then run ./up-linux.sh again."
  exit 1
fi
[[ -f versions.env ]] || { echo "ERROR: versions.env is missing." >&2; exit 1; }

python3 sandbox/scripts/validate-env.py --env-file .env

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

compose() {
  docker compose -p comp_demo --env-file .env --env-file versions.env \
    -f docker-compose.yml "$@"
}

echo "Building and starting ERPNext core services..."
compose up -d --build db redis-cache redis-queue bench

echo "Waiting for MariaDB..."
db_ready=false
for _ in $(seq 1 60); do
  if compose exec -T db sh -lc \
    'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb-admin ping --silent -h 127.0.0.1 -uroot' \
    >/dev/null 2>&1; then
    db_ready=true
    break
  fi
  sleep 2
done
if [[ "$db_ready" != true ]]; then
  echo "ERROR: MariaDB did not become ready. Check: docker compose logs db" >&2
  exit 1
fi

bench_id="$(compose ps -q bench)"
[[ -n "$bench_id" ]] || { echo "ERROR: bench container was not created." >&2; exit 1; }
compose exec -T -u root bench mkdir -p /tmp/comp-demo-bootstrap/lib
docker cp sandbox/scripts/provision-base.sh "$bench_id:/tmp/comp-demo-bootstrap/"
docker cp sandbox/scripts/lib/common.sh "$bench_id:/tmp/comp-demo-bootstrap/lib/"
compose exec -T -u root bench chown -R frappe:frappe /tmp/comp-demo-bootstrap

echo "Provisioning or reusing ERPNext site '$SITE_NAME'..."
compose exec -T bench bash /tmp/comp-demo-bootstrap/provision-base.sh "$FRAPPE_SERIES"

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
    echo "ERPNext is ready at http://localhost:${ERPNEXT_PORT} (site: $SITE_NAME)."
    echo "Install the mounted custom apps with ./install-apps-linux.sh."
    echo "Planner, Shopify/Node-RED, ngrok, and demo data are separate."
    exit 0
  fi
  sleep 3
done

echo "ERROR: ERPNext did not answer its ping endpoint. Check: docker compose logs bench" >&2
exit 1
