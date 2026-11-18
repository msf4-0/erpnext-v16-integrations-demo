#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: ./install-apps-linux.sh

Install the bundled custom apps into an already-provisioned comp_demo site:
barcode_shrdc, shopify, eu_einvoice, item_tracking, metabase_integration,
my_invois. Run ./up-linux.sh first (up-linux.sh already installs these, so this
script is only useful for re-running the installer by hand).
For a one-shot install of every app use the image-baked canonical installer:
  docker compose -p comp_demo --env-file .env --env-file versions.env \
    exec -T bench bash /usr/local/bin/install-all-apps.sh
This does not configure Shopify credentials, Node-RED, ngrok, the planner, or
demo data.
HELP
  exit 0
fi
if (( $# > 0 )); then
  echo "ERROR: this installer takes no options; use --help for details." >&2
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

[[ -f .env ]] || { echo "ERROR: .env is missing; run ./up-linux.sh first." >&2; exit 1; }
[[ -f versions.env ]] || { echo "ERROR: versions.env is missing." >&2; exit 1; }
python3 sandbox/scripts/validate-env.py --env-file .env

env_value() {
  awk -F= -v key="$1" '
    /^[[:space:]]*#/ || !index($0, "=") { next }
    $1 == key { sub(/^[^=]*=/, ""); print; exit }
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

bench_id="$(compose ps -q bench)"
if [[ -z "$bench_id" ]] || [[ "$(docker inspect -f '{{.State.Running}}' "$bench_id" 2>/dev/null || true)" != true ]]; then
  echo "ERROR: the bench container is not running; run ./up-linux.sh first." >&2
  exit 1
fi
if ! compose exec -T -e "SITE_NAME=$SITE_NAME" bench \
  bench --site "$SITE_NAME" list-apps >/dev/null 2>&1; then
  echo "ERROR: site '$SITE_NAME' is not provisioned; run ./up-linux.sh first." >&2
  exit 1
fi

apps=(barcode_shrdc shopify eu_einvoice item_tracking metabase_integration my_invois)
for app in "${apps[@]}"; do
  if ! compose exec -T bench test -d "/home/frappe/frappe-bench/apps/$app"; then
    echo "ERROR: mounted app source '$app' is missing from the bench container." >&2
    exit 1
  fi
done

stage_dir=/tmp/comp-demo-installer
compose exec -T -u root bench mkdir -p "$stage_dir/lib" "$stage_dir/recipes"
docker cp sandbox/scripts/install-app.sh "$bench_id:$stage_dir/"
docker cp sandbox/scripts/fix-barcode-v16-renderdeps.sh "$bench_id:$stage_dir/"
docker cp sandbox/scripts/lib/common.sh "$bench_id:$stage_dir/lib/"
for recipe in barcode_shrdc eu_einvoice item_tracking; do
  docker cp "sandbox/recipes/$recipe.yaml" "$bench_id:$stage_dir/recipes/"
done
compose exec -T -u root bench chown -R frappe:frappe "$stage_dir"

echo "Preparing barcode rendering dependencies..."
compose exec -T -u root bench bash "$stage_dir/fix-barcode-v16-renderdeps.sh"

for app in "${apps[@]}"; do
  recipe=""
  case "$app" in
    barcode_shrdc|eu_einvoice|item_tracking)
      recipe="$stage_dir/recipes/$app.yaml"
      ;;
  esac
  echo "Installing $app..."
  compose exec -T -e "SITE_NAME=$SITE_NAME" bench \
    bash "$stage_dir/install-app.sh" "$app" @mounted "$FRAPPE_SERIES" "$recipe"
done

for app in "${apps[@]}"; do
  if compose exec -T bench test -d \
    "/home/frappe/frappe-bench/apps/$app/$app/public"; then
    echo "Building $app assets..."
    compose exec -T -e "APP=$app" bench bash -lc \
      'export PATH="$(ls -d /home/frappe/.nvm/versions/node/*/bin 2>/dev/null | tail -1):$PATH"; cd /home/frappe/frappe-bench && bench build --app "$APP"'
  fi
done

compose restart bench
site_url="http://localhost:${ERPNEXT_PORT}/api/method/ping"
echo "Waiting for ERPNext at http://localhost:${ERPNEXT_PORT}..."
for _ in $(seq 1 80); do
  if curl --fail --silent --max-time 5 \
    -H "Host: $SITE_NAME" "$site_url" >/dev/null 2>&1; then
    app_list="$(compose exec -T -e "SITE_NAME=$SITE_NAME" bench \
      bench --site "$SITE_NAME" list-apps)"
    printf '%s\n' "$app_list"
    for app in "${apps[@]}"; do
      if ! grep -qE "^${app}([[:space:]]|$)" <<<"$app_list"; then
        echo "ERROR: $app is not listed as installed." >&2
        exit 1
      fi
    done
    echo
    echo "Custom apps are installed on site '$SITE_NAME'."
    echo "Shopify, Node-RED, ngrok, planner setup, and demo data are separate."
    exit 0
  fi
  sleep 3
done

echo "ERROR: ERPNext did not answer its ping endpoint. Check: docker compose logs bench" >&2
exit 1
