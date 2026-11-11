#!/usr/bin/env bash
# Install the server-side barcode renderer deps (reportlab + rlPyCairo) and the
# native cairo headers rlPyCairo needs to build. Must run as ROOT.
#
# Why: the app's print formats rendered barcodes with client-side JsBarcode from
# a CDN (<svg> + <script>), which is blank in frappe's print/PDF pipeline. The
# fix renders them server-side with reportlab to a public PNG. reportlab's
# `asString("png")` needs rlPyCairo on modern reportlab.
set -uo pipefail

echo "== apt: libcairo2-dev + pkg-config (+ a C compiler) =="
# pycairo publishes no cp314 wheel, so pip builds it from source: meson needs a
# compiler on PATH or it dies with "Unknown compiler(s): cc, gcc, clang" while
# generating metadata, and rlPyCairo silently ends up missing (barcode -> PNG
# rendering then fails at print time). The slim image has no gcc, so install it.
APT_PKGS=""
dpkg -s libcairo2-dev >/dev/null 2>&1 || APT_PKGS="$APT_PKGS libcairo2-dev pkg-config"
if ! command -v gcc >/dev/null 2>&1; then
  APT_PKGS="$APT_PKGS build-essential"
fi
if [ -n "$APT_PKGS" ]; then
  echo "  installing:$APT_PKGS"
  apt-get update -qq && apt-get install -y -qq $APT_PKGS
else
  echo "  libcairo2-dev + compiler already installed"
fi

echo
echo "== pip: reportlab + rlPyCairo into the bench venv =="
cd /home/frappe/frappe-bench || exit 1
# frappe's venv lives at ./env; use its pip so the app sees the packages.
./env/bin/pip install -q --no-input reportlab rlPyCairo 2>&1 | tail -5 || true

echo
echo "== probe =="
./env/bin/python - <<'PYEOF'
import sys
try:
    import reportlab
    print("  reportlab", reportlab.Version)
    import rlPyCairo
    print("  rlPyCairo OK")
    from reportlab.graphics.barcode import createBarcodeDrawing
    d = createBarcodeDrawing("Code128", value="123456789012", barHeight=40, barWidth=2, humanReadable=True)
    data = d.asString("png")
    print("  rendered PNG bytes:", len(data), "magic:", data[:4])
except Exception as exc:
    print("  FAIL: server-side barcode rendering is not usable:", exc)
    print("  FAIL: barcode -> PNG/PDF export will fail until this is fixed")
    sys.exit(1)
PYEOF
