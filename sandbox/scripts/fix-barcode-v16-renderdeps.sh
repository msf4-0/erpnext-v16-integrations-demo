#!/usr/bin/env bash
# Install the server-side barcode renderer deps (reportlab + rlPyCairo) and the
# native cairo headers rlPyCairo needs to build. Must run as ROOT.
#
# Why: the app's print formats rendered barcodes with client-side JsBarcode from
# a CDN (<svg> + <script>), which is blank in frappe's print/PDF pipeline. The
# fix renders them server-side with reportlab to a public PNG. reportlab's
# `asString("png")` needs rlPyCairo on modern reportlab.
set -uo pipefail

echo "== apt: libcairo2-dev + pkg-config (idempotent) =="
if ! dpkg -s libcairo2-dev >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq libcairo2-dev pkg-config
else
  echo "  libcairo2-dev already installed"
fi

echo
echo "== pip: reportlab + rlPyCairo into the bench venv =="
cd /home/frappe/frappe-bench || exit 1
# frappe's venv lives at ./env; use its pip so the app sees the packages.
./env/bin/pip install -q --no-input reportlab rlPyCairo 2>&1 | tail -5 || true

echo
echo "== probe =="
./env/bin/python - <<'PYEOF'
import reportlab
print("  reportlab", reportlab.Version)
import rlPyCairo
print("  rlPyCairo OK")
from reportlab.graphics.barcode import createBarcodeDrawing
d = createBarcodeDrawing("Code128", value="123456789012", barHeight=40, barWidth=2, humanReadable=True)
data = d.asString("png")
print("  rendered PNG bytes:", len(data), "magic:", data[:4])
PYEOF
