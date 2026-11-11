# bake/bench.Dockerfile
#
# Builds a SELF-CONTAINED bench image for comp_demo: frappe + erpnext v16 +
# the demo's custom apps (barcode_shrdc, shopify, eu_einvoice) +
# the server-side barcode render deps, all installed AT BUILD TIME so `up.ps1`
# no longer spends ~25-35 min provisioning + installing apps on every recreation.
#
# Why not `docker commit`? A naive commit of the running bench container balloons
# to ~148 GB (see the abandoned `a4h-snap:latest` image) because it captures the
# whole writable layer (apps/env/node_modules/pip caches). A Dockerfile layers
# cleanly and is reproducible.
#
# Build:  docker build -f bake/bench.Dockerfile -t comp_demo-bench:v16 .
#         (from F:\ERPNEXT\erpnextcomp_demo)

# The official ERPNext v16 image already ships frappe + bench + erpnext, so we
# skip the slow, network-flaky `bench get-app erpnext` step entirely. Pin the
# tag for reproducibility (never :latest).
FROM frappe/erpnext:v16.35.0

USER root

# ---------------------------------------------------------------------------
# Native + Python deps for server-side barcode/QR rasterisation, plus redis
# (the running setup installs redis-server at runtime in the writable layer —
# that vanishes on recreate, so bake it here).
# ---------------------------------------------------------------------------
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends \
        libcairo2-dev \
        pkg-config \
        redis-server \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Stage the app sources straight into the bench tree. We deliberately do NOT
# use `bench get-app <local-path>`: bench 5.31.0 (in the current base image)
# regressed on local paths and aborts with "'App' object has no attribute 'org'".
# Copying into apps/ + writing the .pth files below is the equivalent install
# and does not hit the network.
# ---------------------------------------------------------------------------
COPY --chown=frappe:frappe repos/barcode-shrdc-v16-fixed /home/frappe/frappe-bench/apps/barcode_shrdc
COPY --chown=frappe:frappe repos/shopify-shrdc-v16-fixed /home/frappe/frappe-bench/apps/shopify
COPY --chown=frappe:frappe repos/eu_einvoice            /home/frappe/frappe-bench/apps/eu_einvoice

USER frappe
WORKDIR /home/frappe/frappe-bench

# ---------------------------------------------------------------------------
# Put each app on the bench venv's import path by writing its .pth file next to
# the frappe.pth / erpnext.pth that the base image already installed.
# ---------------------------------------------------------------------------
RUN SP=$(dirname "$(find /home/frappe/frappe-bench/env -name 'frappe.pth' -print -quit)") \
    && for app in barcode_shrdc shopify eu_einvoice; do \
        printf '/home/frappe/frappe-bench/apps/%s\n' "$app" > "$SP/${app}.pth"; \
    done \
    && ls -la "$SP"/*.pth

# Server-side rasterisation + QR libs into the bench venv (idempotent, baked once).
RUN /home/frappe/frappe-bench/env/bin/pip install --no-cache-dir reportlab qrcode pillow

# eu_einvoice's own runtime dependencies (its pyproject: factur-x, drafthorse,
# saxonche, lxml). These were never installed, so every request that touched an
# eu_einvoice doctype died in `load_doctype_module` with
#   ModuleNotFoundError: No module named 'drafthorse'
# i.e. clicking E-Invoicing / E Invoice Import threw "Module import failed".
# Pinned to the ranges in repos/eu_einvoice/pyproject.toml.
RUN /home/frappe/frappe-bench/env/bin/pip install --no-cache-dir \
        "factur-x~=3.1" "drafthorse~=2025.2.0" "saxonche>=12.5.0,<13.0.0"

# The running stack runs `sleep infinity` and drives the bench via `exec`. Keep
# that contract so up.ps1's `Invoke-Bench` helpers work unchanged.
USER frappe
CMD ["sleep", "infinity"]
