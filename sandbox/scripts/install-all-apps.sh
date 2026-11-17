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
#   * all eight apps end up in `bench --site <site> list-apps`
#   * correct dependency order (frappe -> erpnext -> barcode_shrdc -> shopify
#     -> eu_einvoice -> item_tracking -> metabase_integration -> my_invois)
#   * no app is installed twice (list-apps is checked first; re-runs are cheap)
#   * a missing app source or a failed install FAILS LOUDLY (exit 1) instead of
#     being skipped, unless ALLOW_PARTIAL=1 is set explicitly
#   * restarts are free: with a complete site it prints the list and exits 0
#
# Env:
#   SITE_NAME         site to install on (default: frontend)
#   SKIP_APPS         space-separated app names to leave uninstalled
#                     (e.g. SKIP_APPS="my_invois" when the LHDN MyInvois layer
#                      conflicts with eu_einvoice on a particular site)
#   ALLOW_PARTIAL=1   downgrade install failures to warnings (NOT for
#                     acceptance testing - the clean-machine test requires 0)
#   INSTALL_APPS      override the full ordered app list
# ---------------------------------------------------------------------------
set -uo pipefail

BENCH_DIR="${BENCH_DIR:-/home/frappe/frappe-bench}"
SITE="${SITE_NAME:-frontend}"
SKIP_APPS="${SKIP_APPS:-}"
ALLOW_PARTIAL="${ALLOW_PARTIAL:-0}"
APPS="${INSTALL_APPS:-frappe erpnext barcode_shrdc shopify eu_einvoice item_tracking metabase_integration my_invois}"

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

installed_list="$(bench --site "$SITE" list-apps 2>/dev/null || true)"
if [ -z "$installed_list" ]; then
    echo "ERROR: 'bench --site $SITE list-apps' returned nothing - the site is not usable." >&2
    exit 1
fi

is_installed() { printf '%s\n' "$installed_list" | grep -qE "^$1([[:space:]]|$)"; }

register_in_apps_txt() {
    local app="$1"
    for f in apps.txt sites/apps.txt; do
        [ -f "$f" ] || continue
        # a file written without a trailing newline would glue the new name
        # onto the previous one ('erpnextmy_invois' - seen in e2e).
        if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then printf '\n' >> "$f"; fi
        grep -qx "$app" "$f" 2>/dev/null || echo "$app" >> "$f"
    done
}

skipped=""
failed=""
to_install=""

for app in $APPS; do
    case " $SKIP_APPS " in
        *" $app "*) echo "-- skip: $app (in SKIP_APPS)"; skipped="$skipped $app"; continue ;;
    esac
    if is_installed "$app"; then
        # apps.txt is bench-level (it drives `bench version`, asset builds and
        # `bench serve`), and a site restored from a dump can have an app
        # installed in the DB while apps.txt only lists frappe/erpnext. Keep the
        # two in sync on every run, not just when installing.
        register_in_apps_txt "$app"
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
    register_in_apps_txt "$app"
    printf '%s\n' "$BENCH_DIR/apps/$app" > "$SP/$app.pth"
    if bench --site "$SITE" install-app "$app"; then
        to_install="$to_install $app"
        # refresh so later iterations see the new state
        installed_list="$(bench --site "$SITE" list-apps 2>/dev/null || true)"
        if ! is_installed "$app"; then
            echo "ERROR: 'bench install-app $app' returned success but the app is not listed." >&2
            failed="$failed $app"
        fi
    else
        echo "ERROR: 'bench install-app $app' failed." >&2
        failed="$failed $app"
    fi
done

if [ -n "$to_install" ]; then
    echo "== migrate (once, after installing:$to_install ) =="
    # A single migrate after the installs is enough and much faster than
    # migrating per app; --skip-search-index keeps it bounded on a demo site.
    if ! bench --site "$SITE" migrate --skip-search-index; then
        echo "ERROR: 'bench migrate' failed after installing apps." >&2
        failed="$failed migrate"
    fi
    bench --site "$SITE" clear-cache || true
    bench --site "$SITE" clear-website-cache || true
else
    echo "== no new apps to install - migrate skipped =="
fi

# ---------------------------------------------------------------------------
# Verification: every app that was meant to be installed must be listed AND
# importable in the bench venv (import is what load_doctype_module does).
# ---------------------------------------------------------------------------
echo "== verification =="
final_list="$(bench --site "$SITE" list-apps 2>/dev/null || true)"
printf '%s\n' "$final_list"
for app in $APPS; do
    case " $SKIP_APPS " in *" $app "*) continue ;; esac
    printf '%s\n' "$final_list" | grep -qE "^$app([[:space:]]|$)" || {
        echo "ERROR: $app is NOT installed on $SITE" >&2
        failed="$failed $app"
    }
done

# import check runs against the same interpreter the bench uses
if ! env/bin/python - "$APPS" "$SKIP_APPS" <<'PY'
import importlib, sys
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
