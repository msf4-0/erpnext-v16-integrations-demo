#!/usr/bin/env bash
# Debug: why did show_sku=1 not persist on the seeded doc?
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
cat > /tmp/_dbg_sku.py <<'PYEOF'
import frappe
from frappe.db import get_value
docname = open("/tmp/bppf/doc.txt").read().strip()
print("MARK docname", docname)
print("MARK db show_sku", get_value("Barcode Printing", docname, "show_sku"))
d = frappe.get_doc("Barcode Printing", docname)
print("MARK doc show_sku", d.show_sku, "| modified", d.modified)
d.show_sku = 1
d.show_serial_no = 1
d.show_batch_no = 1
d.flags.ignore_validate_update_after_submit = True
try:
    d.save(ignore_permissions=True)
    frappe.db.commit()
    print("MARK save OK; db now", get_value("Barcode Printing", docname, "show_sku"))
except Exception as e:
    import traceback; traceback.print_exc()
    print("MARK save ERROR", type(e).__name__, e)
PYEOF
bench --site "$SITE" console < /tmp/_dbg_sku.py 2>&1 | grep -E '^MARK|Error|Traceback|File ' | sed 's/^/  /'
