# bake/bench.Dockerfile
#
# Builds a SELF-CONTAINED bench image for comp_demo: frappe + erpnext v16 +
# the demo's custom apps (barcode_shrdc, shopify, eu_einvoice) + the server-side
# barcode render deps, all installed AT BUILD TIME so `up.ps1` no longer spends
# ~25-35 min provisioning + installing apps on every recreation.
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

# Stage the app sources (they live in this repo under repos/).
COPY repos/barcode-shrdc-v16-fixed /opt/apps/barcode_shrdc
COPY repos/shopify-shrdc-v16-fixed /opt/apps/shopify
COPY repos/eu_einvoice            /opt/apps/eu_einvoice

# ---------------------------------------------------------------------------
# Bake the bench tree + custom apps as the frappe user.
# NOTE: `bench get-app <local-path>` links a local checkout into apps/ without
# hitting the network. erpnext is already present from the base image.
# ---------------------------------------------------------------------------
USER frappe
WORKDIR /home/frappe/frappe-bench

RUN bench get-app /opt/apps/barcode_shrdc \
    && bench get-app /opt/apps/shopify \
    && bench get-app /opt/apps/eu_einvoice

# Server-side rasterisation libs into the bench venv (idempotent, baked once).
RUN /home/frappe/frappe-bench/env/bin/pip install --no-cache-dir reportlab rlPyCairo

# The running stack runs `sleep infinity` and drives the bench via `exec`. Keep
# that contract so up.ps1's `Invoke-Bench` helpers work unchanged.
USER frappe
CMD ["sleep", "infinity"]
