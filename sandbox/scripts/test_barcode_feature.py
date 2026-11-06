# -*- coding: utf-8 -*-
import frappe

frappe.init(site="frontend", sites_path="/home/frappe/frappe-bench/sites")
frappe.connect()

se = frappe.get_all(
    "Stock Entry",
    filters={"stock_entry_type": "Manufacture", "docstatus": 1},
    order_by="modified desc",
    limit=1,
)
if not se:
    print("NO submitted Manufacture Stock Entry found; nothing to test.")
else:
    name = se[0]["name"]
    doc = frappe.get_doc("Stock Entry", name)
    finished = [d for d in doc.items if d.t_warehouse and (d.qty or 0) > 0]
    print("Testing on:", name, "finished rows:", len(finished))
    from item_tracking.item_tracking.events import _create_finished_good_barcode_printing

    bp = _create_finished_good_barcode_printing(doc)
    if bp:
        print("OK - Barcode Printing created:", bp.name)
        for row in bp.items:
            print("  item=%s serials=%s" % (row.item_code, (row.serial_no or "").replace("\n", ",")))
    else:
        print("FAIL - no Barcode Printing document returned")

frappe.destroy()
