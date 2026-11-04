import frappe
frappe.init(site="frontend", sites_path="/home/frappe/frappe-bench/sites")
frappe.connect()
import os
os.makedirs("/home/frappe/frappe-bench/sites/frontend/logs", exist_ok=True)
try:
    bp = frappe.get_doc("Barcode Printing", "BP-2026-11-04-00001")
except Exception as e:
    print("BP ERR", repr(e))
    frappe.destroy()
    raise SystemExit
print("BP items:", len(bp.items))
for it in bp.items:
    print("  code=%r barcode=%r btype=%r qty=%r" % (it.item_code, it.barcode, it.barcode_type, it.qty))
# test the preview function directly
from barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing import get_preview_html
try:
    html = get_preview_html({"items": [{"item_code": "TEST", "barcode": "TEST123", "barcode_type": "CODE128", "qty": 1, "rate": 10}]}, "sku")
    print("PREVIEW LEN:", len(html or ""))
    print(html[:400])
except Exception as e:
    import traceback; traceback.print_exc()
frappe.destroy()
