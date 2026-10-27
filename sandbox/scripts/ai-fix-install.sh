#!/usr/bin/env bash
# ai-fix-install.sh — container-side (bench container, `frappe` user) installer
# for the ERPNEXT-AI-FIX stack.
#
# Installs, in order:
#   1. barcode_shrdc  — the operator's downloaded source, with the v16 runtime
#                       fix chain applied, then exported back to the host as a
#                       durable fork so later runs need no patching.
#   2. shopify        — the v16-fixed fork.
#   3. an ERPNext API token for Administrator (consumed by the Node-RED flow).
#
# Inputs staged by sandbox/up.ps1 into the container:
#   /tmp/scripts/   this workspace's sandbox/scripts/*
#   /tmp/recipes/   sandbox/recipes/*
#   /tmp/repos/     the app sources
#
# Usage (inside the container):
#   bash /tmp/scripts/ai-fix-install.sh
set -uo pipefail

SCRIPTDIR="${SCRIPTDIR:-/tmp/scripts}"
RECIPEDIR="${RECIPEDIR:-/tmp/recipes}"
REPODIR="${REPODIR:-/tmp/repos}"
EXPORTDIR="${EXPORTDIR:-/tmp/export}"
VERSION="${ERPNEXT_VERSION:-16}"
SITE="${SITE_NAME:-frontend}"
HOST_URL="${HOST_URL:-http://localhost:8000}"

BENCH="/home/frappe/frappe-bench"
cd "$BENCH" || { echo "ERROR: $BENCH missing"; exit 1; }
mkdir -p "$EXPORTDIR"

step() { echo; echo "==================== $* ===================="; }
fails=()

# ---------------------------------------------------------------------------
# 0. preconditions
# ---------------------------------------------------------------------------
step "0/4 preconditions"
for f in "$SCRIPTDIR/install-app.sh" "$SCRIPTDIR/lib/common.sh"; do
  [ -f "$f" ] || { echo "ERROR: missing $f — did up.ps1 stage it?"; exit 1; }
done
bench --site "$SITE" list-apps >/dev/null 2>&1 || {
  echo "ERROR: site '$SITE' is not provisioned yet — run provision-base.sh first"; exit 1; }
echo "-- site $SITE is present"

# ---------------------------------------------------------------------------
# 1. barcode_shrdc — the barcode scanner / printing app
# ---------------------------------------------------------------------------
step "1/4 barcode_shrdc"
BARCODE_SRC=""
if [ -d "$REPODIR/barcode-shrdc-v16-fixed" ]; then
  BARCODE_SRC="$REPODIR/barcode-shrdc-v16-fixed"
  echo "-- source: durable fixed fork (carries every v16 fix; NO patching)"
elif [ -d "$REPODIR/barcode-shrdc-master" ]; then
  BARCODE_SRC="$REPODIR/barcode-shrdc-master"
  echo "-- source: the operator's ERPNext-Barcode-Integration download"
  echo "   (upstream master — the v16 fix chain runs after install)"
else
  echo "ERROR: no barcode source under $REPODIR"; exit 1
fi

if bash "$SCRIPTDIR/install-app.sh" barcode_shrdc "$BARCODE_SRC" "$VERSION" \
     "$RECIPEDIR/barcode_shrdc.yaml"; then
  echo "-- barcode_shrdc installed"
else
  echo "ERROR: barcode_shrdc install failed"; fails+=("barcode_shrdc install")
fi

# The upstream download still carries the v15-era runtime bugs on v16:
#   * barcode lookup called the no-longer-whitelisted get_item_code
#   * "Create QR" on an unsaved doc 404s
#   * save crashed on item.serial_no.split
#   * print formats used a CDN JsBarcode that renders blank in PDF
# fix-barcode-v16.sh is idempotent and covers all of them.
if [ ! -d "$REPODIR/barcode-shrdc-v16-fixed" ]; then
  step "1b/4 barcode_shrdc v16 fix chain"
  if bash "$SCRIPTDIR/fix-barcode-v16.sh"; then
    echo "-- v16 fix chain completed"
  else
    echo "WARN: the v16 fix chain reported failures — barcode features may be partial"
    fails+=("barcode v16 fix chain")
  fi

  step "1c/4 export the patched tree as the durable fork"
  # From here on, every rebuild installs this tree and skips the patch chain.
  rm -rf "$EXPORTDIR/barcode-shrdc-v16-fixed"
  if cp -a apps/barcode_shrdc "$EXPORTDIR/barcode-shrdc-v16-fixed"; then
    rm -rf "$EXPORTDIR/barcode-shrdc-v16-fixed/.git"
    find "$EXPORTDIR/barcode-shrdc-v16-fixed" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
    echo "-- exported $(find "$EXPORTDIR/barcode-shrdc-v16-fixed" -type f | wc -l) files to $EXPORTDIR"
  else
    echo "WARN: could not export the patched tree"; fails+=("barcode export")
  fi
fi

# ---------------------------------------------------------------------------
# 2. shopify — the ERPNext side of the Shopify bridge
# ---------------------------------------------------------------------------
step "2/4 shopify"
SHOPIFY_SRC="$REPODIR/shopify-shrdc-v16-fixed"
if [ -d "$SHOPIFY_SRC" ]; then
  if bash "$SCRIPTDIR/install-app.sh" shopify "$SHOPIFY_SRC" "$VERSION" \
       "$RECIPEDIR/shopify.yaml"; then
    echo "-- shopify installed"
  else
    echo "ERROR: shopify install failed"; fails+=("shopify install")
  fi
else
  echo "WARN: $SHOPIFY_SRC missing — skipping shopify"
  fails+=("shopify source missing")
fi

# ---------------------------------------------------------------------------
# 3. site-level config the print/PDF pipeline needs
# ---------------------------------------------------------------------------
step "3/4 host_name"
# Without host_name, get_url() returns the container hostname, which the
# in-container wkhtmltopdf cannot resolve -> HostNotFoundError on every PDF.
bench --site "$SITE" set-config host_name "$HOST_URL" >/dev/null 2>&1 \
  && echo "-- host_name = $HOST_URL" \
  || echo "WARN: could not set host_name"

# ---------------------------------------------------------------------------
# 4. API token for the Node-RED flow
# ---------------------------------------------------------------------------
step "4/4 ERPNext API token for Node-RED"
cat > apps/barcode_shrdc/barcode_shrdc/_aifix_token.py <<'PYEOF'
import frappe


def run(user="Administrator"):
	"""Mint a fresh api_key/api_secret pair for `user` and print it."""
	api_key = frappe.generate_hash(length=15)
	api_secret = frappe.generate_hash(length=15)
	frappe.db.set_value("User", user, {"api_key": api_key, "api_secret": api_secret})
	frappe.db.commit()
	print("MARK_TOKEN %s:%s" % (api_key, api_secret))
PYEOF

TOKEN_LINE=$(bench --site "$SITE" execute barcode_shrdc._aifix_token.run 2>&1 | grep -o 'MARK_TOKEN .*' || true)
rm -f apps/barcode_shrdc/barcode_shrdc/_aifix_token.py
find apps/barcode_shrdc -name '_aifix_token*' -delete 2>/dev/null || true

TOKEN="${TOKEN_LINE#MARK_TOKEN }"
if [ -n "$TOKEN" ] && [ "${TOKEN#*:}" != "$TOKEN" ]; then
  printf '%s' "$TOKEN" > "$EXPORTDIR/erpnext_token.txt"
  echo "-- token written to $EXPORTDIR/erpnext_token.txt (${TOKEN%%:*}...)"
else
  echo "ERROR: could not mint an API token"
  fails+=("api token")
fi

# ---------------------------------------------------------------------------
# finalise
# ---------------------------------------------------------------------------
step "summary"
bench --site "$SITE" list-apps 2>&1 | sed 's/^/  /'
echo
echo "-- serve ping: $(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SITE" http://localhost:8000/api/method/ping)"

echo
if [ "${#fails[@]}" -gt 0 ]; then
  echo "AI-FIX-INSTALL: COMPLETED WITH ERRORS"
  for f in "${fails[@]}"; do echo "  - $f"; done
  exit 1
fi
echo "AI-FIX-INSTALL: OK"
