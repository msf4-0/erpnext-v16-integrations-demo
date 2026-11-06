# Metabase ↔ ERPNext Dashboard Guide (comp_demo)

Environment: **Metabase** http://localhost:3005 · **ERPNext** http://localhost:8000

---

## 0. Diagnosis — "is the ERPNext connection not successful?"

**The connection is fine.** Verified live:

- Metabase data source **`ERPNext`** (`id=2`, engine `mysql`, host `db:3306`, db `_35e1999d62da474b`) is registered and fully synced — **1017 tables**.
- MySQL grants are correct: `GRANT SELECT, SHOW VIEW ON _35e1999d62da474b.* TO metabase_user@'%'`.
- Real row counts exist:

| Table | Rows |
|---|---|
| `tabSales Order` | 260 |
| `tabPurchase Order` | 9 |
| `tabWork Order` | 24 |
| `tabJob Card` | 51 |
| `tabWorkstation` | 7 |
| `tabStock Ledger Entry` | 274 |
| `tabDelivery Note` | 10 |
| `tabSales Invoice` | 7 |

**Why your bar chart showed no data:** the question `TabStock Ledger Entry + TabItem`
was saved with `visualization_settings.graph.metrics = [null]` and no aggregation in the
query. A bar chart needs a **metric** (Count / Sum / Average). Without one, Metabase
renders nothing even though the data is there. (I added a `Count` metric to it; rebuild
it with the SQL below for a proper breakdown.)

---

## 1. Building the requested dashboards (paste as native SQL questions)

In Metabase: **+ New → SQL query → select data source `ERPNext` → paste → Save → add to a dashboard.**

### 1a. Sales Order monitoring — pie chart (tab "Sales Order")
```sql
SELECT status AS "Status", COUNT(*) AS "Orders"
FROM `tabSales Order`
GROUP BY status
ORDER BY COUNT(*) DESC
```
Visualize as **Pie** (rows = Status / Orders). Optionally group by `customer` or
`grand_total` buckets instead of `status`.

### 1b. Purchase Order monitoring
```sql
SELECT status AS "Status", COUNT(*) AS "Orders", SUM(grand_total) AS "Value"
FROM `tabPurchase Order`
GROUP BY status
```

### 1c. Workstation monitoring — Job Card + Workstation (+ Work Order)
```sql
SELECT w.workstation_name AS "Workstation",
       COUNT(j.name)              AS "Job Cards",
       COUNT(DISTINCT j.work_order) AS "Work Orders",
       COALESCE(SUM(j.for_quantity),0)          AS "Planned Qty",
       COALESCE(SUM(j.total_completed_qty),0)   AS "Completed Qty"
FROM `tabJob Card` j
LEFT JOIN `tabWorkstation` w ON w.name = j.workstation
GROUP BY w.workstation_name
ORDER BY "Job Cards" DESC
```

### 1d. Sales Order delivery status (tab "Delivery Status")
```sql
SELECT so.status AS "SO Status",
       COALESCE(SUM(soi.qty),0)           AS "Ordered Qty",
       COALESCE(SUM(dni.qty),0)           AS "Delivered Qty",
       COALESCE(SUM(soi.qty),0) - COALESCE(SUM(dni.qty),0) AS "Pending Qty"
FROM `tabSales Order` so
LEFT JOIN `tabSales Order Item` soi ON soi.parent = so.name
LEFT JOIN `tabDelivery Note Item` dni ON dni.against_sales_order = so.name
GROUP BY so.status
```

### 1e. Basic metadata dashboard (any table)
Use **X-ray** or point a card at any ERPNext table. The key rule every card must obey:
**a bar/pie/line chart needs exactly (1) one breakout dimension + (2) one aggregation metric.**

---

## 2. How to embed Metabase charts/questions into ERPNext

1. **Admin → Settings → Embedding** (in Metabase) → toggle **Enable embedding** → copy the **Embedding secret key**.
2. In ERPNext, the Metabase integration comes from the `Metabase Dashboard` page. Open
   **Search → "Metabase Settings"** and fill:
   - **Server URL** = `http://localhost:3005`
   - **Secret Key** = the embedding secret key from step 1.
3. In Metabase, open the dashboard → **Sharing → Embed this dashboard in an application → Publish → Code** → copy the **dashboard id**.
4. In ERPNext, **Metabase Dashboard → New** → set **Dashboard ID** = that id → Save.
5. The dashboard now renders inside ERPNext. For auto-refresh append `#refresh=30` to the URL.

> Note: this `comp_demo` bench is **stock ERPNext v16** — there is no `Metabase Dashboard`
> doctype installed out of the box (the guide you pasted assumes a preinstalled integration
> app). If the page is missing, install a Metabase integration app (e.g. the `frappe_metabase`
> / `metabase_integration` app) or embed via an iframe on a Workspace / Web Page.

---

## 3. STOCK ENTRY (Manufacture) — auto barcode for finished product (FIFO)

**Requirement:** when a *Manufacture*-type Stock Entry is submitted, each finished-good row
(`is_finished_item` / target warehouse) gets a barcode/serial id, and a bottom-right
notification (like the standard save/submit toast) confirms it.

### Where to put it (this workspace)
Add a `doc_events` hook in the existing **`item_tracking`** app (it already owns
`Tracked Item` + scan popup) or **`barcode_shrdc`**.

1. `repos/item_tracking/item_tracking/hooks.py`:
   ```python
   doc_events = {
       "Stock Entry": {
           "on_submit": "item_tracking.events.stock_entry.on_submit"
       }
   }
   ```
2. `repos/item_tracking/item_tracking/events/stock_entry.py`:
   ```python
   import frappe
   from frappe.utils import cint

   @frappe.whitelist()
   def on_submit(doc, method):
       if doc.stock_entry_type != "Manufacture":
           return
       for row in doc.items:
           if not row.is_finished_item:
               continue
           # one serial/barcode per finished good, FIFO-friendly (use serial_no)
           for _ in range(cint(row.qty)):
               serial = create_barcode(row)
           frappe.msgprint(
               f"Finished good {row.item_code} complete — barcode/serial {serial}",
               indicator="green", alert=True,   # alert=True => bottom-right toast
           )
   ```
3. `create_barcode` writes the barcode to the `Tracked Item` doctype (or `barcode_shrdc`)
   and stores the **serial no → finished-good item** link, then emits a barcode via the
   existing `barcode_shrdc` rendering so it can be printed/scanned (FIFO = each unit is a
   distinct serial, consumed oldest-first).

### Rebuild + migrate after editing
```powershell
docker exec comp_demo-bench-1 bash -lc "cd /home/frappe/frappe-bench && bench --site frontend migrate && bench clear-cache"
```
(The site DB user is `_35e1999d62da474b`, password in `sites/frontend/site_config.json` —
do **not** reuse `metabase_user` for app writes; it is SELECT-only.)

---

## 4. Registering this change (required by workspace policy)
Add a row to `Customisations.md` (Kind **C** doc_events) and list the new files. Rollback
tier **1** (disable) — simply remove the `doc_events` entry.
