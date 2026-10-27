#!/usr/bin/env bash
# Probe whether reportlab can render a linear barcode to PNG in this venv.
# Also report whether the cairo system headers are present.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
echo "== system cairo headers =="
dpkg -l 2>/dev/null | grep -iE 'libcairo2-dev|pkg-config' || echo "  (none installed)"
echo
echo "== python packages =="
env/bin/pip list 2>/dev/null | grep -iE 'reportlab|rlpycairo|qrcode|pillow' || echo "  (none)"
echo
echo "== try import reportlab + render PNG =="
env/bin/python - <<'PYEOF'
try:
    import reportlab
    print("  reportlab", reportlab.Version)
except Exception as e:
    print("  reportlab MISSING:", type(e).__name__, e)
    raise SystemExit
try:
    from reportlab.graphics.barcode import createBarcodeDrawing
    d = createBarcodeDrawing("Code128", value="123456789012", barHeight=40, barWidth=2, humanReadable=True)
    data = d.asString("png")
    print("  rendered PNG bytes:", len(data), "magic:", data[:4])
except Exception as e:
    print("  render ERROR:", type(e).__name__, e)
PYEOF
