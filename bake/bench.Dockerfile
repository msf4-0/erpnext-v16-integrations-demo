# bake/bench.Dockerfile
#
# Builds a SELF-CONTAINED bench image for comp_demo: frappe + erpnext v16 +
# ALL SIX custom apps + their Python dependencies, installed AT BUILD TIME.
#
# P7 (reproducible fresh deployment): the image must contain every app the
# site installs, so a clean clone needs no bind mounts, no `docker cp`, no
# manual folder placement. The apps are vendored in ./repos (git-tracked,
# 324 files) and copied in here. The build FAILS LOUDLY if any app source is
# missing or malformed - a partially-populated image is worse than no image.
#
# App -> bench app name mapping (directory name is NOT the app name):
#   repos/barcode-shrdc-v16-fixed -> barcode_shrdc
#   repos/shopify-shrdc-v16-fixed -> shopify
#   repos/item_tracking           -> item_tracking
#   repos/metabase_integration    -> metabase_integration
#   repos/my_invois               -> my_invois
#
# Build:  docker compose build bench
#         (from the repository root; reads ERPNEXT_BASE from versions.env)
#   or:   docker build -f bake/bench.Dockerfile \
#           --build-arg ERPNEXT_BASE=frappe/erpnext:v16.35.0 -t comp_demo-bench:v16 .

# The official ERPNext image already ships frappe + bench + erpnext, so we skip
# the slow, network-flaky `bench get-app erpnext` step entirely. The caller
# supplies the base image from the root `versions.env` file.
ARG ERPNEXT_BASE
FROM ${ERPNEXT_BASE}

USER root

# ---------------------------------------------------------------------------
# Native + Python deps for server-side barcode/QR rasterisation, plus redis
# (the running setup installed redis-server at runtime in the writable layer,
# which vanished on recreate, so it is baked here).
# ---------------------------------------------------------------------------
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends \
        libcairo2-dev \
        pkg-config \
        redis-server \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Stage every app source straight into the bench tree. We deliberately do NOT
# use `bench get-app <local-path>`: bench 5.31.0 (in the current base image)
# regressed on local paths and aborts with "'App' object has no attribute 'org'".
# Copying into apps/ + writing the .pth files below is the equivalent install
# and does not hit the network.
# ---------------------------------------------------------------------------
COPY --chown=frappe:frappe repos/barcode-shrdc-v16-fixed   /home/frappe/frappe-bench/apps/barcode_shrdc
COPY --chown=frappe:frappe repos/shopify-shrdc-v16-fixed   /home/frappe/frappe-bench/apps/shopify
COPY --chown=frappe:frappe repos/item_tracking             /home/frappe/frappe-bench/apps/item_tracking
COPY --chown=frappe:frappe repos/metabase_integration      /home/frappe/frappe-bench/apps/metabase_integration
COPY --chown=frappe:frappe repos/my_invois                 /home/frappe/frappe-bench/apps/my_invois

# The canonical first-time installer is baked in so the `seed` one-shot service
# and the bench container run the SAME code path (no bind mount needed).
COPY --chown=frappe:frappe sandbox/scripts/install-all-apps.sh /usr/local/bin/install-all-apps.sh
RUN chmod 0755 /usr/local/bin/install-all-apps.sh

USER frappe
WORKDIR /home/frappe/frappe-bench

# ---------------------------------------------------------------------------
# BUILD-TIME GUARD: every app must look like a real Frappe app. This turns a
# missing/gutted source tree into a failed build instead of an image that
# starts and then dies with ModuleNotFoundError at first page load.
# ---------------------------------------------------------------------------
RUN set -eu; \
    fail=0; \
    for app in barcode_shrdc shopify item_tracking metabase_integration my_invois; do \
        if [ ! -f "apps/$app/$app/hooks.py" ]; then \
            echo "BUILD ERROR: apps/$app/$app/hooks.py is missing (app source not vendored?)" >&2; fail=1; fi; \
        if [ ! -f "apps/$app/$app/__init__.py" ]; then \
            echo "BUILD ERROR: apps/$app/$app/__init__.py is missing" >&2; fail=1; fi; \
        if ! grep -qE '^__version__[[:space:]]*=' "apps/$app/$app/__init__.py" 2>/dev/null; then \
            echo "BUILD ERROR: apps/$app/$app/__init__.py has no __version__ (frappe cannot load it)" >&2; fail=1; fi; \
    done; \
    [ "$fail" -eq 0 ] || exit 1; \
    echo "app-source guard: all 5 custom app sources present and well-formed"

# ---------------------------------------------------------------------------
# Put each app on the bench venv's import path by writing its .pth file next to
# the frappe.pth / erpnext.pth that the base image already installed.
# ---------------------------------------------------------------------------
RUN SP=$(dirname "$(find /home/frappe/frappe-bench/env -name 'frappe.pth' -print -quit)") \
    && for app in barcode_shrdc shopify item_tracking metabase_integration my_invois; do \
        printf '/home/frappe/frappe-bench/apps/%s\n' "$app" > "$SP/${app}.pth"; \
    done \
    && ls -la "$SP"/*.pth

# ---------------------------------------------------------------------------
# Register every app in sites/apps.txt INSIDE the image.
#
# Docker seeds a fresh bench_sites volume from this directory, so the base
# image's apps.txt (frappe + erpnext only) is what a clean clone starts with.
# Frappe builds its module map from apps.txt, and `bench migrate` deletes every
# DocType/Workspace/Report whose module is not on that map as an "orphan". With
# the custom apps missing here, the seed's migrate silently removed Tracked
# Item, Barcode Printing, etc. from the restored demo site.
# ---------------------------------------------------------------------------
RUN set -eu; \
    for f in sites/apps.txt apps.txt; do \
        [ -f "$f" ] || continue; \
        if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then printf '\n' >> "$f"; fi; \
        for app in barcode_shrdc shopify item_tracking metabase_integration my_invois; do \
            grep -qx "$app" "$f" || echo "$app" >> "$f"; \
        done; \
    done; \
    echo "sites/apps.txt:"; cat sites/apps.txt

# ---------------------------------------------------------------------------
# Bake the GLOBAL site config endpoints into the image.
#
# The base image's sites/common_site_config.json contains only `default_site`.
# Docker copies image content into a fresh named volume, so on a clean clone the
# seeder's old "write it only if missing" guard never fired: every bench command
# resolved db_host=localhost:3306 and redis://localhost:6379, and
# `bench migrate` aborted with "Service redis_cache is not running" while the
# site kept serving without cache or queue. Writing the compose service names
# here makes a fresh volume correct from the first second.
# ---------------------------------------------------------------------------
RUN /home/frappe/frappe-bench/env/bin/python - <<'PY'
import json
import os

path = "/home/frappe/frappe-bench/sites/common_site_config.json"
os.makedirs(os.path.dirname(path), exist_ok=True)
cfg = {}
if os.path.exists(path):
    try:
        with open(path) as handle:
            cfg = json.load(handle) or {}
    except Exception:  # noqa: BLE001
        cfg = {}
cfg.update(
    {
        "db_host": "db",
        "db_port": 3306,
        "redis_cache": "redis://redis-cache:6379",
        "redis_queue": "redis://redis-queue:6379",
        "redis_socketio": "redis://redis-queue:6379",
        "socketio_port": 9000,
    }
)
with open(path, "w") as handle:
    json.dump(cfg, handle, indent=1)
print("baked common_site_config ->", ", ".join(sorted(cfg)))
PY

# Server-side rasterisation + QR libs into the bench venv (idempotent, baked once).
RUN /home/frappe/frappe-bench/env/bin/pip install --no-cache-dir reportlab qrcode pillow

# Every app's own requirements.txt. A failing requirements file fails the build: a half-installed
# app is exactly the "Module import failed" class of bug this image exists to
# avoid. `--no-deps` is NOT used - transitive deps are wanted here.
RUN for app in barcode_shrdc shopify item_tracking metabase_integration my_invois; do \
        if [ -f "apps/$app/requirements.txt" ] && [ -s "apps/$app/requirements.txt" ]; then \
            echo "== pip install -r apps/$app/requirements.txt =="; \
            /home/frappe/frappe-bench/env/bin/pip install --no-cache-dir \
                -r "apps/$app/requirements.txt"; \
        else \
            echo "== apps/$app has no requirements.txt - nothing to install =="; \
        fi; \
    done

# ---------------------------------------------------------------------------
# IMPORT SMOKE TEST: importing each app package is what Frappe does on every
# request (`load_doctype_module`). Catching it here means a missing dependency
# breaks the build, not the demo.
# ---------------------------------------------------------------------------
RUN cd /home/frappe/frappe-bench && env/bin/python - <<'PY'
import importlib, sys
apps = ["barcode_shrdc", "shopify", "item_tracking",
        "metabase_integration", "my_invois"]
failed = []
for app in apps:
    try:
        mod = importlib.import_module(app)
        print(f"import ok: {app} {getattr(mod, '__version__', '?')}")
    except Exception as exc:                     # noqa: BLE001
        failed.append((app, repr(exc)))
if failed:
    for app, exc in failed:
        print(f"IMPORT FAILED: {app}: {exc}", file=sys.stderr)
    sys.exit(1)
PY

# The running stack runs `sleep infinity` and drives the bench via `exec`. Keep
# that contract so up.ps1's `Invoke-Bench` helpers work unchanged.
USER frappe
CMD ["sleep", "infinity"]
