#!/usr/bin/env bash
# rebuild.sh — ONE COMMAND to (re)build the entire erpnext-sandbox.
#
# Why this exists: the bench lives in the container's writable layer, so a
# container recreate wipes every installed app and every in-container fix. This
# script makes that cost one command instead of a dozen manual steps, by
# chaining the already-banked scripts in the correct order.
#
# RUNS ON THE HOST (it needs `docker compose`). Use Git Bash / WSL:
#   bash sandbox/rebuild.sh                 # keep the container/DB, reinstall apps
#   bash sandbox/rebuild.sh --fresh         # down -v first (FULL data wipe)
#   VERSION=15 bash sandbox/rebuild.sh --fresh
#
# NOTE on --fresh: `down -v` deletes the DB and sites volumes. That is the
# point (a truly clean rebuild), but it is destructive — hence opt-in.
set -uo pipefail

PROJECT="${PROJECT:-erpnext-sandbox}"
VERSION="${VERSION:-16}"
SITE="${SITE:-frontend}"
FRESH=0
[ "${1:-}" = "--fresh" ] && FRESH=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 1

dc()  { docker compose -p "$PROJECT" -f ./sandbox/docker-compose.yml "$@"; }
dex() { dc exec -T "$@"; }
step() { echo; echo "===== $* ====="; }
die() { echo "ERROR: $*" >&2; exit 1; }

# App sources to stage, as "<host dir under repos/>:<name in /tmp>". These names
# MUST match rebuild-apps.sh's APPS manifest.
STAGE=(
  "barcode-shrdc-v16:barcode-shrdc-v16"
  "amazon-integration:amazon-integration-src"
)

step "0. preflight"
[ -d ./repos ] || die "no ./repos dir; nothing to install"
[ -f ./sandbox/docker-compose.yml ] || die "sandbox/docker-compose.yml not found"
command -v docker >/dev/null || die "docker not on PATH"
for s in "${STAGE[@]}"; do
  d="${s%%:*}"; [ -d "./repos/$d" ] || die "app source ./repos/$d missing"
done

if [ "$FRESH" -eq 1 ]; then
  step "1. down -v  (DESTRUCTIVE: wipes DB + sites volumes)"
  dc down -v || die "compose down failed"
fi

step "2. up -d"
dc up -d || die "compose up failed"
echo "  waiting for db to settle..."; sleep 5

step "3. copy scripts + recipes into the container"
dex bench bash -lc "mkdir -p /tmp/scripts/lib /tmp/recipes" || die "mkdir failed"
HOST_SCRIPTS="provision-base.sh install-app.sh ensure-root-prep.sh rebuild-apps.sh \
fix-barcode-v16-renderdeps.sh fix-barcode-v16.sh fix-barcode-v16-py.sh \
fix-barcode-v16-js.sh fix-barcode-v16-preview.sh fix-barcode-v16-printformats.sh \
fix-barcode-v16-hostname.sh fix-barcode-v16-bump.sh"
for f in $HOST_SCRIPTS; do
  [ -f "./sandbox/scripts/$f" ] && dc cp "./sandbox/scripts/$f" "bench:/tmp/scripts/$f" >/dev/null
done
dc cp ./sandbox/scripts/lib/common.sh bench:/tmp/scripts/lib/common.sh >/dev/null
[ -f ./sandbox/scripts/lib/barcode_v16_print_formats.json ] && \
  dc cp ./sandbox/scripts/lib/barcode_v16_print_formats.json bench:/tmp/barcode_v16_print_formats.json >/dev/null
for y in ./sandbox/recipes/*.yaml; do
  [ -f "$y" ] || continue
  dc cp "$y" "bench:/tmp/recipes/$(basename "$y")" >/dev/null
done
echo "  copied."

step "4. stage app sources into /tmp/<name>"
for s in "${STAGE[@]}"; do
  d="${s%%:*}"; name="${s##*:}"
  dc cp "./repos/$d" "bench:/tmp/$name" >/dev/null && echo "  staged $name"
done

step "5. root prep BEFORE provision (chown bench dir + redis-server)"
dex -u root bench bash -lc \
  "chown -R frappe:frappe /home/frappe/frappe-bench 2>/dev/null; bash /tmp/scripts/ensure-root-prep.sh" \
  || die "root prep failed"

step "6. provision the ERPNext v$VERSION base"
dex bench bash -lc "/tmp/scripts/provision-base.sh $VERSION" || die "provision failed"

step "7. root render deps AFTER provision (needs env/ from bench init)"
dex -u root bench bash -lc "bash /tmp/scripts/fix-barcode-v16-renderdeps.sh" \
  || echo "  WARN: render deps failed; barcode print formats will be text-only"

step "8. install/rebuild the apps"
dex bench bash -lc "VERSION=$VERSION /tmp/scripts/rebuild-apps.sh" || die "app rebuild failed"

step "9. verify"
dex bench bash -lc \
  "curl -s -o /dev/null -w 'ping=%{http_code}\n' -H 'Host: $SITE' http://localhost:8000/api/method/ping; bench --site $SITE list-apps"

echo
echo "REBUILD COMPLETE (v$VERSION, site $SITE)."
echo "Containers: $(dc ps --format '{{.Name}} {{.Status}}' 2>/dev/null | tr '\n' '; ')"
