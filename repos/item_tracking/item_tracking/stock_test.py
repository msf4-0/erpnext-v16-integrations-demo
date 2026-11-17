import frappe


def _find_stock_item():
    it = frappe.db.get_value("Item", {"is_stock_item": 1, "disabled": 0}, "name", order_by="name")
    if not it:
        frappe.throw("No stock item found")
    return it


def _find_warehouses():
    whs = [d.name for d in frappe.get_all("Warehouse", filters={"is_group": 0, "disabled": 0},
                                          fields=["name"], order_by="name", limit=4)]
    if len(whs) < 2:
        frappe.throw("Need at least 2 warehouses, found %s" % whs)
    return whs


def _make_se(stock_entry_type, item, tracked_ids, s_wh=None, t_wh=None):
    se = frappe.new_doc("Stock Entry")
    se.stock_entry_type = stock_entry_type
    if t_wh:
        se.to_warehouse = t_wh
    if s_wh:
        se.from_warehouse = s_wh
    for tid in tracked_ids:
        se.append("items", {
            "item_code": item,
            "qty": 1,
            "s_warehouse": s_wh,
            "t_warehouse": t_wh,
            "basic_rate": 0, "allow_zero_valuation_rate": 1,
            "conversion_factor": 1,
        })
        se.append("tracked_items", {
            "tracked_item": tid,
            "item_code": item,
        })
    se.insert(ignore_permissions=True)
    return se


def run():
    out = []
    item = _find_stock_item()
    whs = _find_warehouses()
    w1, w2 = whs[0], whs[1]
    out.append("item=%s w1=%s w2=%s" % (item, w1, w2))

    from item_tracking.item_tracking.doctype.tracked_item.tracked_item import bulk_create_tracked_items
    ids = bulk_create_tracked_items(item, 2)
    out.append("tracked: %s" % ids)

    # Test 4a: Material Receipt into w1 -> location should become w1
    se = _make_se("Material Receipt", item, ids, t_wh=w1)
    se.submit()
    out.append("receipt submitted: %s" % se.name)
    for tid in ids:
        d = frappe.get_doc("Tracked Item", tid)
        out.append("  after receipt: %s -> %s (%s)" % (tid, d.current_warehouse, d.current_status))
        assert d.current_warehouse == w1, "receipt should put item in %s" % w1
        assert len(d.item_tracking_history) >= 1, "history should be recorded"

    # Test 4b: Material Transfer w1 -> w2 for ids[0] only
    se2 = _make_se("Material Transfer", item, [ids[0]], s_wh=w1, t_wh=w2)
    se2.submit()
    out.append("transfer submitted: %s" % se2.name)
    d0 = frappe.get_doc("Tracked Item", ids[0])
    out.append("  after transfer: %s -> %s" % (ids[0], d0.current_warehouse))
    assert d0.current_warehouse == w2, "transfer should move item to %s" % w2
    d1 = frappe.get_doc("Tracked Item", ids[1])
    assert d1.current_warehouse == w1, "other item should remain in %s" % w1

    # Test 5: invalid movement - transfer ids[1] from w2 (but it's in w1)
    bad = _make_se("Material Transfer", item, [ids[1]], s_wh=w2, t_wh=w1)
    blocked = False
    try:
        bad.submit()
    except Exception as e:
        blocked = True
        out.append("  invalid movement blocked: %s" % str(e)[:80])
    assert blocked, "invalid movement must be blocked"

    # Test 8: duplicate scan in one SE
    dup = frappe.new_doc("Stock Entry")
    dup.stock_entry_type = "Material Transfer"
    dup.from_warehouse = w2
    dup.to_warehouse = w1
    dup.append("items", {"item_code": item, "qty": 1, "s_warehouse": w2, "t_warehouse": w1,
                         "basic_rate": 0, "allow_zero_valuation_rate": 1, "conversion_factor": 1})
    dup.append("tracked_items", {"tracked_item": ids[0], "item_code": item})
    dup.append("tracked_items", {"tracked_item": ids[0], "item_code": item})
    dup.insert(ignore_permissions=True)
    dup_blocked = False
    try:
        dup.submit()
    except Exception as e:
        dup_blocked = True
        out.append("  duplicate blocked: %s" % str(e)[:80])
    assert dup_blocked, "duplicate scan must be blocked"

    # Test 6: cancel the transfer -> ids[0] should return to w1
    se2.cancel()
    d0 = frappe.get_doc("Tracked Item", ids[0])
    out.append("  after cancel: %s -> %s" % (ids[0], d0.current_warehouse))
    assert d0.current_warehouse == w1, "cancel should restore %s" % w1

    out.append("=== ALL STOCK ENTRY CHECKS PASSED ===")
    return "\n".join(out)
