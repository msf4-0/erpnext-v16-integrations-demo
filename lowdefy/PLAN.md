# Lowdefy Smart Inventory & Exception Management — Implementation Plan

> Authoritative stack architecture, ports, versions, and database durability:
> [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

## 0. Current status (honest)

| Item | State |
|---|---|
| ERPNext v16 (site `frontend`) | **Down.** Docker Desktop daemon is not running, so `localhost:8000` is unreachable. |
| Lowdefy | **Not installed.** No Lowdefy project existed anywhere under `F:\ERPNEXT`. |
| Real ERPNext data | Unavailable until the stack is brought up (`up.ps1` / `setup.ps1`, ~25–35 min rebuild on this host). |

Because ERPNext is down and Lowdefy is not installed, **nothing below has been run against live data yet**. This document is the plan + a working scaffold; integration testing is blocked on the two items above.

## 1. Architecture

```
ERPNext v16  (source of truth: Item, Bin, Serial No, Batch, Stock Ledger, Stock Entry,
              Purchase Order, Purchase Receipt, Warehouse, User)
      ▲  REST + token auth (token lives ONLY server-side, never in the browser/YAML)
      │
      ▼
Lowdefy app  ──►  Lowdefy connections (AxiosHttp) ──► ERPNext /api/resource/*
      ▲
      │  JSON
      ▼
Exception Service (Node/Express, port 4000)   <-- server-side detection + exception metadata
      ├─ detects: low stock, out of stock, overdue PO, delayed delivery,
      │           pending transfer, unusual movement, discrepancy, expiring batch
      ├─ dedup by stable key (e.g. `low_stock:{item}:{warehouse}`)
      └─ persists exception lifecycle (New→Investigating→Resolved / Dismissed)
                              in SQLite (separate from ERPNext — inventory stays in ERPNext)
```

- **ERPNext is the source of truth** for inventory, serials, batches, and transactions.
- **Lowdefy is the operational UI** (read + initiate transfers + investigate).
- **The Exception Service** holds only exception *metadata* (status, assignee, notes, activity), never a duplicate copy of stock levels.

## 2. ERPNext REST endpoints used (fields requested minimally)

| Purpose | Endpoint | Key fields |
|---|---|---|
| Items | `GET /api/resource/Item` | name, item_name, item_group, is_stock_item, disabled |
| Warehouse | `GET /api/resource/Warehouse` | name, warehouse_name, parent_warehouse, disabled |
| Bin (real qty) | `GET /api/resource/Bin` | item_code, warehouse, actual_qty, projected_qty, reserved_qty, stock_value |
| Reorder | `GET /api/resource/Item Reorder` | parent (item), warehouse, warehouse_reorder_level, material_request_type |
| Serial No | `GET /api/resource/Serial No` | name, item_code, warehouse, status, purchase_document_no |
| Batch | `GET /api/resource/Batch` | name, item, expiry_date, stock_uom, batch_qty |
| Stock Entry | `GET /api/resource/Stock Entry` | name, stock_entry_type, from_warehouse, to_warehouse, docstatus, posting_date, items |
| Stock Ledger | `GET /api/resource/Stock Ledger Entry` | item_code, warehouse, actual_qty, qty_after_transaction, voucher_type, voucher_no, posting_date |
| Purchase Order | `GET /api/resource/Purchase Order` | name, supplier, schedule_date, docstatus, per_received, items |
| Purchase Receipt | `GET /api/resource/Purchase Receipt` | name, docstatus, items |
| Stock Reconciliation | `GET /api/resource/Stock Reconciliation` | name, docstatus, items, posting_date |
| User / roles | `GET /api/method/frappe.auth.get_logged_user`, `GET /api/resource/User` | name, roles |

Pagination: every list call uses `limit_start`/`limit_page_length` and `fields=[...]`.

## 3. Secrets & security

All credentials are injected via environment variables, resolved **server-side** by Lowdefy `_secret` references and by the Exception Service's `process.env`. Nothing is hardcoded in YAML or shipped to the browser.

```
ERPNEXT_URL              http://localhost:8000
ERPNEXT_API_KEY          <token key>
ERPNEXT_API_SECRET       <token secret>
EXCEPTION_DB_PATH        path to exception SQLite file
EXCEPTION_PORT           4000
LOWDEFY_PORT             3000
```

RBAC: the frontend hides buttons by role; the **Exception Service re-validates** the ERPNext token's roles on every mutating endpoint (transfers, assign, resolve, dismiss). Hiding a button is never the only control.

## 4. Build stages (per the brief's FINAL INSTRUCTION)

1. **Stage 1 — connection + inventory read** (this scaffold): Lowdefy app boots, connects to ERPNext, lists Items + Bin stock with real quantities.
2. **Stage 2 — Smart Inventory**: searchable/filterable table, item detail panel, serial tracking, warehouse filters.
3. **Stage 3 — QR/Barcode scanner**: `html5-qrcode` via a Lowdefy custom block; manual entry fallback; serial lookup by identifier.
4. **Stage 4 — Stock movements**: read Stock Entry / Stock Ledger; initiate a **draft** Material Transfer (serialized items carry serial nos), submit only after ERPNext validation succeeds.
5. **Stage 5 — Exception Centre**: server-side detection + lifecycle + right-side detail panel.
6. **Stage 6 — Reports & Analytics**: charts from real retrieved data only.

## 5. Known limitations / requires additional config

- **Serial tracking**: ERPNext items must have `has_serial_no=1` (Serialized). If an item is not serialized, serial numbers cannot be invented — the app must explain the required Item configuration instead.
- **Camera QR scanning** needs a browser with camera permission; a manual-entry fallback is always present. `html5-qrcode` is a client-side JS lib, integrated as a Lowdefy custom block/plugin (not native Lowdefy).
- **Batch expiry** exceptions only fire when `Batch.expiry_date` actually exists.
- **Unusual movement** rules need operator-set thresholds (configurable in Settings), not hardcoded heuristics.
- **Discrepancies** only when a `Stock Reconciliation` with counted values exists — the app never invents a physical count.
- **`docker compose up -d` hangs on this host** — use the project's own `up.ps1`/`setup.ps1`; the DB is stored in `db_data` and persists across Docker restarts.

## 6. What still must be done (not yet built)

- Install Lowdefy and verify the exact installed version's YAML schema against these files.
- Bring up ERPNext (`setup.ps1`), mint a REST token, run the Exception Service, and test every workflow end-to-end (transfers, serials, exceptions) against real records — never against fabricated data.
