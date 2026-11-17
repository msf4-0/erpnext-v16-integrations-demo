import frappe

def run():
    rows = frappe.db.sql("""select name, dt, view, enabled from `tabClient Script`""", as_dict=True)
    hits = []
    for r in rows:
        body = frappe.db.get_value("Client Script", r.name, "script") or ""
        if "get_serial_summary" in body or "ensure_serials" in body or "get_items_barcode" in body.lower():
            hits.append({"name": r.name, "dt": r.dt, "view": r.view, "enabled": r.enabled,
                         "len": len(body), "snippet": body[:600]})
    print({"total": len(rows), "hits": hits})
