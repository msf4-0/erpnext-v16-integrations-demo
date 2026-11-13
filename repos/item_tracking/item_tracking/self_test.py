import frappe


def run():
    out = []
    out.append("=== 1. Doctypes ===")
    for dt in ["Tracked Item", "Item Tracking History", "Stock Entry Tracked Item"]:
        out.append("  %s: %s" % (dt, "OK" if frappe.db.exists("DocType", dt) else "MISSING"))

    out.append("=== 2. Custom field ===")
    out.append("  Stock Entry.tracked_items: %s" % (
        "OK" if frappe.db.exists("Custom Field", "Stock Entry-tracked_items") else "MISSING"))

    out.append("=== 3. Test item ===")
    item = frappe.db.get_value("Item", {"name": ["like", "SHRDC%"]}, "name", order_by="name")
    if not item:
        item = frappe.db.get_value("Item", {}, "name", order_by="name")
    out.append("  item: %s" % item)

    out.append("=== 4. Bulk create 5 tracked items ===")
    from item_tracking.item_tracking.doctype.tracked_item.tracked_item import bulk_create_tracked_items
    ids = bulk_create_tracked_items(item, 5)
    out.append("  created: %s" % ids)
    assert len(set(ids)) == 5, "IDs must be unique"

    out.append("=== 5. Unique barcode/QR per unit ===")
    seen_bc, seen_qr = set(), set()
    for tid in ids:
        d = frappe.get_doc("Tracked Item", tid)
        out.append("  %s | item=%s | barcode=%s | qr=%s" % (tid, d.item_code, d.barcode, d.qr_code))
        seen_bc.add(d.barcode)
        seen_qr.add(d.qr_code)
    assert len(seen_bc) == 5 and len(seen_qr) == 5, "barcode/QR must be unique"

    out.append("=== 6. Lookup (by id, barcode, QR url) ===")
    from item_tracking.item_tracking.api import lookup_tracked_item
    r1 = lookup_tracked_item(ids[0])
    out.append("  by id: %s | %s" % (r1.get("tracking_id"), r1.get("item_name")))
    r2 = lookup_tracked_item(frappe.get_doc("Tracked Item", ids[1]).barcode)
    out.append("  by barcode: %s" % r2.get("tracking_id"))
    r3 = lookup_tracked_item("http://host/tracked_item_lookup?tracking_id=%s" % ids[2])
    out.append("  by QR url: %s" % r3.get("tracking_id"))
    assert r1.get("tracking_id") == ids[0]
    assert r2.get("tracking_id") == ids[1]
    assert r3.get("tracking_id") == ids[2]

    out.append("=== ALL CORE CHECKS PASSED ===")
    return "\n".join(out)
