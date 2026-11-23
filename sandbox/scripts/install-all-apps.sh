#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-all-apps.sh - install EVERY comp_demo app onto the ERPNext site.
#
# This is the single canonical "apps get installed on the site" code path. It
# is baked into the bench image at /usr/local/bin/install-all-apps.sh, so the
# one-shot `seed` service and any manual `docker compose exec bench ...` call
# run identical logic. Do not add a second installer.
#
# Runs INSIDE the bench container, from anywhere (it cd's to the bench root).
#
# What it guarantees:
#   * all seven apps end up installed on the site
#   * correct dependency order (frappe -> erpnext -> barcode_shrdc -> shopify
#     -> item_tracking -> metabase_integration -> my_invois)
#   * no app is installed twice (the DB is checked first; re-runs are cheap)
#   * a missing app source or a failed install FAILS LOUDLY (exit 1) instead of
#     being skipped, unless ALLOW_PARTIAL=1 is set explicitly
#   * restarts are free: with a complete site it prints the list and exits 0
#
# Env:
#   SITE_NAME         site to install on (default: frontend)
#   SKIP_APPS         space-separated app names to leave uninstalled
#                     (e.g. SKIP_APPS="my_invois" when the LHDN MyInvois layer
#                      conflicts with another e-invoicing app on a site)
#   ALLOW_PARTIAL=1   downgrade install failures to warnings (NOT for
#                     acceptance testing - the clean-machine test requires 0)
#   INSTALL_APPS      override the full ordered app list
# ---------------------------------------------------------------------------
set -uo pipefail

BENCH_DIR="${BENCH_DIR:-/home/frappe/frappe-bench}"
SITE="${SITE_NAME:-frontend}"
SKIP_APPS="${SKIP_APPS:-}"
ALLOW_PARTIAL="${ALLOW_PARTIAL:-0}"
APPS="${INSTALL_APPS:-frappe erpnext barcode_shrdc shopify item_tracking metabase_integration my_invois}"

cd "$BENCH_DIR" || { echo "ERROR: bench dir $BENCH_DIR not found" >&2; exit 1; }

echo "== install-all-apps: site '$SITE' =="

if [ ! -f "sites/$SITE/site_config.json" ]; then
    echo "ERROR: site '$SITE' does not exist (no sites/$SITE/site_config.json)." >&2
    echo "       The seeder/provisioner must create or restore the site first." >&2
    exit 1
fi

# site-packages of the bench venv, wherever python version the base image uses
SP="$(dirname "$(find "$BENCH_DIR/env" -name 'frappe.pth' -print -quit 2>/dev/null)")"
if [ -z "${SP:-}" ] || [ ! -d "$SP" ]; then
    echo "ERROR: could not locate the bench venv site-packages (frappe.pth not found)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# SOURCE OF TRUTH = the database.
#
# `bench list-apps` is NOT reliable here: on this bench it reports only
# frappe/erpnext for a site that has all eight apps installed (reproduced on a
# restored demo dump), while `frappe.get_installed_apps()` returns the truth
# from `tabInstalled Application`. Deciding from list-apps made the installer
# re-install already-present apps and then, when list-apps still lagged, abort
# the seed with a bogus "finished INCOMPLETE".
# ---------------------------------------------------------------------------
db_apps() {
    bench --site "$SITE" execute frappe.get_installed_apps 2>/dev/null \
        | tr -d "[]'\"" | tr ',' '\n' | tr -d ' ' | sed '/^$/d'
}

apps_txt_changed=0
register_in_apps_txt() {
    local app="$1"
    [ -f sites/apps.txt ] || touch sites/apps.txt
    for f in apps.txt sites/apps.txt; do
        [ -f "$f" ] || continue
        # a file written without a trailing newline would glue the new name
        # onto the previous one ('erpnextmy_invois' - seen in e2e).
        if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then printf '\n' >> "$f"; fi
        if ! grep -qx "$app" "$f" 2>/dev/null; then
            echo "$app" >> "$f"
            [ "$f" = "sites/apps.txt" ] && apps_txt_changed=1
        fi
    done
}

is_installed() { printf '%s\n' "${db_list:-}" | grep -qx "$1"; }

# ---------------------------------------------------------------------------
# DocTypes shipped by an app's source but absent from the site's DocType table.
#
# "Installed" (a row in tabInstalled Application) does not mean "synced". When
# `bench migrate` runs while an app is missing from sites/apps.txt, Frappe's
# remove_orphan_doctypes() deletes that app's DocTypes, Workspaces and Reports,
# yet the app still counts as installed - so a plain "is it installed?" check
# skips it forever and the desk shows no Tracked Item / Barcode Printing.
# ---------------------------------------------------------------------------
missing_doctypes() {
    env/bin/python - "$SITE" "$@" <<'PY' 2>/dev/null
import glob
import json
import os
import sys

import frappe

site, apps = sys.argv[1], sys.argv[2:]
os.chdir("sites")
frappe.init(site=site, sites_path=".")
frappe.connect()
missing = []
try:
    for app in apps:
        for path in sorted(glob.glob(f"../apps/{app}/{app}/*/doctype/*/*.json")):
            stem = os.path.splitext(os.path.basename(path))[0]
            if os.path.basename(os.path.dirname(path)) != stem:
                continue
            try:
                with open(path) as handle:
                    meta = json.load(handle)
            except Exception:  # noqa: BLE001
                continue
            if meta.get("doctype") != "DocType" or not meta.get("name"):
                continue
            if not frappe.db.exists("DocType", meta["name"]):
                missing.append(f"{app}:{meta['name']}")
finally:
    frappe.destroy()
print("\n".join(missing))
PY
}

custom_apps() {
    for app in $APPS; do
        case "$app" in frappe|erpnext) continue ;; esac
        case " $SKIP_APPS " in *" $app "*) continue ;; esac
        [ -d "apps/$app" ] && printf '%s ' "$app"
    done
}

# Register every app that has source in the image, so sites/apps.txt (which
# drives `bench version`, asset builds and `bench serve`) matches what is about
# to be installed, then read the authoritative installed set.
for app in $APPS; do
    [ -d "apps/$app" ] && register_in_apps_txt "$app"
done
[ "$apps_txt_changed" = "1" ] && echo "-- sites/apps.txt was missing apps - a migrate will re-sync them"

db_list="$(db_apps)"
if [ -z "$db_list" ]; then
    echo "ERROR: 'frappe.get_installed_apps' returned nothing - the site is not usable." >&2
    exit 1
fi
echo "-- installed before this run: $(printf '%s ' $db_list)"

skipped=""
failed=""
to_install=""

for app in $APPS; do
    case " $SKIP_APPS " in
        *" $app "*) echo "-- skip: $app (in SKIP_APPS)"; skipped="$skipped $app"; continue ;;
    esac
    if is_installed "$app"; then
        echo "-- present: $app"
        continue
    fi
    # frappe/erpnext are baked into the base image and installed at new-site
    # time; if either is missing the site itself is broken.
    if [ ! -d "apps/$app" ]; then
        echo "ERROR: source for '$app' is missing at apps/$app - the bench image is incomplete." >&2
        failed="$failed $app"
        continue
    fi
    echo "-- installing: $app"
    printf '%s\n' "$BENCH_DIR/apps/$app" > "$SP/$app.pth"
    if bench --site "$SITE" install-app "$app"; then
        to_install="$to_install $app"
        db_list="$(db_apps)"
        if ! is_installed "$app"; then
            echo "ERROR: 'bench install-app $app' reported success but the app is not in" >&2
            echo "       tabInstalled Application. Registration did not take effect." >&2
            failed="$failed $app"
        fi
    else
        echo "ERROR: 'bench install-app $app' failed." >&2
        failed="$failed $app"
    fi
done

doctype_check_failed=0
missing_before="$(missing_doctypes $(custom_apps))" || doctype_check_failed=1
if [ "$doctype_check_failed" = "1" ]; then
    echo "-- WARN: could not compare app DocTypes with the site - migrating to be safe"
elif [ -n "$missing_before" ]; then
    echo "-- DocTypes missing from the site (installed but never synced, or deleted as orphans):"
    printf '%s\n' "$missing_before" | sed 's/^/     /'
fi

migrate_reason=""
[ -n "$to_install" ] && migrate_reason="installed:$to_install"
[ "$apps_txt_changed" = "1" ] && migrate_reason="$migrate_reason apps.txt-updated"
[ -n "$missing_before" ] && migrate_reason="$migrate_reason missing-doctypes"
[ "$doctype_check_failed" = "1" ] && migrate_reason="$migrate_reason doctype-check-failed"
[ "${FORCE_MIGRATE:-0}" = "1" ] && migrate_reason="$migrate_reason FORCE_MIGRATE"

if [ -n "$migrate_reason" ]; then
    echo "== migrate (once; reason:$migrate_reason ) =="
    # A single migrate after the installs is enough and much faster than
    # migrating per app; --skip-search-index keeps it bounded on a demo site.
    if ! bench --site "$SITE" migrate --skip-search-index; then
        echo "ERROR: 'bench migrate' failed after installing apps." >&2
        failed="$failed migrate"
    fi
    bench --site "$SITE" clear-cache || true
    bench --site "$SITE" clear-website-cache || true
else
    echo "== apps installed, registered and synced - migrate skipped =="
fi

missing_after="$(missing_doctypes $(custom_apps))" || missing_after="(DocType check could not run)"
if [ -n "$missing_after" ]; then
    echo "ERROR: these app DocTypes are still missing from '$SITE' after migrate:" >&2
    printf '%s\n' "$missing_after" | sed 's/^/     /' >&2
    failed="$failed doctypes"
else
    echo "-- every DocType shipped by:$(printf ' %s' $(custom_apps)) is present on the site"
fi

# ---------------------------------------------------------------------------
# Verification: every app that was meant to be installed must be in the DB, be
# listed by the bench, and import in the bench venv (import is what
# load_doctype_module does on every request).
# ---------------------------------------------------------------------------
echo "== verification =="
db_list="$(db_apps)"

# ---------------------------------------------------------------------------
# site_config.json must list the installed apps as well as the database.
#
# `bench new-site` writes "installed_apps": ["frappe"], and restoring a dump
# replaces the DATABASE only - the file keeps that one-entry list. Frappe builds
# the Jinja template loader from this key, so on a restored site every www/ page
# shipped by a custom app answered HTTP 500 ("TemplateNotFound") while core
# pages were fine. The DB was correct all along; only this file was stale.
# Writing the authoritative DB list here fixes seed, up-linux.sh and manual
# runs in one place (it is the canonical installer).
# ---------------------------------------------------------------------------
if env/bin/python - "$SITE" "$(printf '%s ' $db_list)" <<'PY'
import json
import sys

site, apps = sys.argv[1], sys.argv[2].split()
path = f"sites/{site}/site_config.json"
with open(path) as handle:
    cfg = json.load(handle)
if cfg.get("installed_apps") == apps:
    print("site_config: installed_apps already current")
else:
    cfg["installed_apps"] = apps
    with open(path, "w") as handle:
        json.dump(cfg, handle, indent=1)
    print("site_config: installed_apps -> " + " ".join(apps))
PY
then
    bench --site "$SITE" clear-cache >/dev/null 2>&1 || true
else
    echo "ERROR: could not synchronise installed_apps in site_config.json" >&2
    failed="$failed site-config"
fi

echo "-- installed (db): $(printf '%s ' $db_list)"
echo "-- list-apps:"
bench --site "$SITE" list-apps 2>&1 | sed 's/^/   /'

for app in $APPS; do
    case " $SKIP_APPS " in *" $app "*) continue ;; esac
    is_installed "$app" || {
        echo "ERROR: $app is NOT installed on $SITE" >&2
        failed="$failed $app"
    }
done

if ! env/bin/python - "$APPS" "$SKIP_APPS" <<'PY'
import importlib
import sys

apps = sys.argv[1].split()
skip = sys.argv[2].split()
bad = []
for app in apps:
    if app in skip:
        continue
    try:
        importlib.import_module(app)
    except Exception as exc:  # noqa: BLE001
        bad.append(f"{app}: {exc!r}")
if bad:
    print("IMPORT FAILED: " + "; ".join(bad), file=sys.stderr)
    sys.exit(1)
print("import ok: " + ", ".join(a for a in apps if a not in skip))
PY
then
    failed="$failed import"
fi

if [ -n "$failed" ]; then
    if [ "$ALLOW_PARTIAL" = "1" ]; then
        echo "WARN: incomplete install:$failed (ALLOW_PARTIAL=1, continuing)" >&2
        exit 0
    fi
    echo "ERROR: install-all-apps finished INCOMPLETE. Failed:$failed" >&2
    exit 1
fi

echo "== install-all-apps: done - all requested apps installed on '$SITE' =="
