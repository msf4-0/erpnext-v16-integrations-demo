#!/usr/bin/env bash
# Replay a recorded Shopify order into ERPNext without a store or a token.
#
# Usage: ./replay.sh [payload.json] [site]
set -euo pipefail
cd "$(dirname "$0")"
payload="${1:-payloads/order-1001.json}"
site="${2:-${SITE_NAME:-frontend}}"
container="${COMPOSE_PROJECT:-comp_demo}-bench-1"

[ -f "$payload" ] || { echo "replay: no such payload: $payload" >&2; exit 2; }
docker inspect "$container" >/dev/null 2>&1 || {
  echo "replay: container $container is not running - start the stack first" >&2; exit 2; }

docker cp "$payload" "$container:/tmp/shopify-order.json"
docker cp replay.py "$container:/tmp/shopify-replay.py"
docker cp replay-in-container.sh "$container:/tmp/shopify-replay.sh"
docker exec "$container" bash /tmp/shopify-replay.sh "$site"
