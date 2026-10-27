#!/usr/bin/env bash
# Dump print-format HTML for the barcode formats from the fixture file,
# and show whether they use CDN JsBarcode / data-URI / svg.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
cat > /tmp/_pf.py <<'PYEOF'
import json
d = json.load(open("apps/barcode_shrdc/barcode_shrdc/fixtures/print_format.json"))
for pf in d:
    html = pf.get("html") or ""
    print("MARK ---- format:", pf.get("name"), "| custom_format:", pf.get("custom_format"), "| len:", len(html))
    for needle in ("jsdelivr", "JsBarcode", "<svg", "data:image", "get_barcode_image", "get_qr_image", "doc.qrcodes", "resize:", "overflow:", "height: 35.75mm", "show_sku", "show_serial_no", "show_batch_no"):
        if needle in html:
            print("MARK   contains:", needle)
PYEOF
/home/frappe/frappe-bench/env/bin/python /tmp/_pf.py
