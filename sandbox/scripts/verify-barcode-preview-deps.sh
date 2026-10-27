#!/usr/bin/env bash
# Verify helpers the preview fix relies on.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
env/bin/python - <<'PYEOF'
try:
    from frappe.utils import escape_html
    print("  escape_html from frappe.utils: OK ->", escape_html("<b>&hi"))
except Exception as e:
    print("  escape_html from frappe.utils: FAIL", type(e).__name__, e)
try:
    import hashlib
    print("  hashlib: OK")
except Exception as e:
    print("  hashlib FAIL", e)
PYEOF

echo
echo "== how does the desk open the print preview? (v16) =="
F=apps/frappe/frappe
grep -rn "printview\|get_html_and_style\|make_pdf\|print_preview" "$F/public/js/frappe/printing" "$F/printing/page/print/print.js" 2>/dev/null | head -20 | sed 's/^/  /'
grep -rn "printview\|get_html_and_style" "$F/public/js/frappe/utils/utils.js" 2>/dev/null | head -10 | sed 's/^/  /'
