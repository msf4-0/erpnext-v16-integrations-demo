bp = frappe.get_doc("Barcode Printing", "BP-2026-11-04-00001")
it = bp.items[0]
print("CODE=%r BARCODE=%r BTYPE=%r QTY=%r" % (it.item_code, it.barcode, it.barcode_type, it.qty))
ib = frappe.get_all("Item Barcode", filters={"parent": it.item_code}, fields=["barcode", "barcode_type"])
print("ITEM-BARCODE-ROWS:", ib)
print("ITEM-NAME:", frappe.db.get_value("Item", it.item_code, "item_name"))
