# Assessment — E-Invoicing + Barcode/QR Item Tracking

> Authoritative configured stack architecture, ports, image pins, and database
> durability: [`ARCHITECTURE.md`](ARCHITECTURE.md). Version values below are
> observations from the dated live-environment assessment.

> Investigation date: 2026-11-04. Project: this repository on a Windows host (Docker
> project `comp_demo`, site `frontend`, ERPNext v16). This document records the
> *current* state before any implementation, per the task's "assess before
> modifying" requirement.

## 0. Environment facts (measured)

| Fact | Value |
|---|---|
| Stack | ERPNext `16.53.0` / Frappe `16.54.0`, MariaDB 11.8 (`db_data` volume) |
| Installed apps | `frappe`, `erpnext`, `barcode_shrdc 0.0.1`, `shopify 0.0.1`, `eu_einvoice 16.3.0`, **`item_tracking 0.0.1`** |
| Containers up | bench (8000), scheduler (3001), node-red (1880), db, redis ×2 — all Up |
| App sources | `repos/{barcode-shrdc-v16-fixed, shopify-shrdc-v16-fixed, eu_einvoice, item_tracking}` |

`docs/MILESTONES.md` is **stale**: it lists only 5 apps and omits `item_tracking`,
which is in fact installed on the live site. Its "Malaysia LHDN" gap note is still
accurate (see §2).

---

## PART 1 — E-Invoicing

### 1. What exists today

The e-invoicing app is **`eu_einvoice` (alyf-de, v16.3.0)** — a **European**
e-invoicing app, not a Malaysia one.

- **Generation:** builds an **EN 16931 / UN-CEFACT CII** `CrossIndustryInvoice`
  XML and an **XRechnung** (German) variant; auto-attaches
  `ACC-SINV-2026-00001.xml` to a Sales Invoice. Evidence: `eu_einvoice/common_codes.py`,
  `jinja.py`, codelists (`VATEX.gc`, `EAS.gc`, `1001.gc` = CII), `switzerland.py`.
- **Import:** `E Invoice Import` doctype reads **XRechnung XML / ZUGFeRD PDF**
  into supplier/number/dates/totals, then creates a Purchase Invoice.
- **Validation:** validates against European tax IDs / VAT exemption codes,
  **not** Malaysia TIN / BRN / SST.
- **No submission:** there is no MyInvois / LHDN API client, no Document UUID,
  no submission/acceptance/rejection/cancellation lifecycle, no validation-link
  or LHDN QR. It only *formats* and *imports* European documents.

### 2. Gap vs the Malaysia (LHDN MyInvois) requirement

| Requirement | Status |
|---|---|
| MyInvois API integration (sandbox + prod) | ❌ absent |
| TIN / BRN (Malaysia) | ❌ absent (EU VAT/EAS only) |
| Malaysia tax classifications (SST, MSIC, etc.) | ❌ absent |
| LHDN submission / acceptance / rejection / cancellation | ❌ absent |
| Document UUID, LHDN validation link / QR | ❌ absent |

`docs/MILESTONES.md` records the reason: *"the substituted app is EU EN 16931 /
XRechnung (CII), not MyInvois; the original MY source is 404."*

### 3. Conclusion

The current `eu_einvoice` does **not** do Malaysia e-invoicing. It is an honest
European implementation that has been substituted in. Without a MyInvois app
source and/or real LHDN client credentials, official submission **cannot** be
claimed. The correct scope is: keep `eu_einvoice` as-is (it works for EU), and
build a **Malaysia integration-ready layer** (TIN/BRN fields, SST tax
classifications, MyInvois payload preparation, status lifecycle, and an API
client behind sandbox/production config) — with submission gated on credentials.

---

## PART 2 — Barcode / QR Item Tracking

There are **two** distinct apps doing related work:

1. **`barcode_shrdc`** — barcode **printing** (`Barcode Printing`, `Barcode
   Configuration`, `QR Code Configuration`) and **scan-to-Delivery-Note/Stock-Entry**
   via Client Scripts. Works (MILESTONES M8/M9/M9b verified).
2. **`item_tracking`** — the "Item Tracker" the task refers to. Per-physical-unit
   tracking with a `Tracked Item` doctype (unique `tracking_id`, barcode, QR),
   `item_tracking_history` child, and a `tracked_items` child table on Stock
   Entry / Delivery Note. Its scan popup is `public/js/item_tracking_scan.js`.

### 1. Problem 1 — "Item Tracker Stock Entry error"

The **backend** Stock Entry lifecycle is correct and passes its own test. Ran
against the live site:

```
item=WHL-001 w1=Finished Goods - SHRDC w2=Goods In Transit - SHRDC
tracked: ['WHL-001-0001', 'WHL-001-0002']
receipt submitted: MAT-STE-2026-00052
  after receipt: WHL-001-0001 -> Finished Goods - SHRDC (In Stock)
  after receipt: WHL-001-0002 -> Finished Goods - SHRDC (In Stock)
transfer submitted: MAT-STE-2026-00053
  after transfer: WHL-001-0001 -> Goods In Transit - SHRDC
  invalid movement blocked: ...
  duplicate blocked: ...
  after cancel: WHL-001-0001 -> Finished Goods - SHRDC
=== ALL STOCK ENTRY CHECKS PASSED ===
```

So submit/cancel/history/duplicate/warehouse-mismatch all work **server-side**
(`item_tracking/item_tracking/events.py`). The reported error is therefore in the
**UI path**, `item_tracking.scan_into_stock_entry(frm)`
(`public/js/item_tracking_scan.js` lines 59–102):

- It adds an `items` row with only `item_code` + `qty` — **no `s_warehouse` /
  `t_warehouse`**, so a Material Transfer/Receipt row is incomplete and fails
  ERPNext's own warehouse validation on save/submit.
- It relies on `item_tracking` being defined (from `app_include_js`). If the
  bundle is not built/served after the app was installed, clicking
  **Scan Tracked Item** throws `item_tracking is not defined`.
- `frm.script_manager.trigger('item_code', it.doctype, it.name)` does not set
  warehouses either.

**Root cause to fix:** make the client script populate the full Stock Entry item
row (warehouse from the transaction header), and guarantee the JS bundle is
built and served (`bench build --app item_tracking`). Verify with a real UI
submit, not just the backend test.

### 2. Problem 2 — "Item Tracker disconnected / separate window"

Two concrete causes:

**(a) The QR payload points at a standalone web page.** `TrackedItem.validate()`
sets `qr_code = _tracked_item_qr_url(tracking_id)` →
`<site>/tracked_item_lookup?tracking_id=...`, a `www/` page
(`www/tracked_item_lookup.html`). Scanning it with a camera opens a **detached
website page** — exactly the behaviour the task forbids. The same URL is baked by
`get_tracking_qr_image()`.

**(b) There is no in-Desk camera scanner.** `item_tracking.scan()` only shows a
text `frappe.prompt`; nothing activates the camera. The inline popup machinery
(`item_tracking.show_popup`, a `frappe.ui.Dialog`) **already exists and is
app-wide**, but nothing feeds it from a live camera.

The fix direction is already half-built: keep `show_popup()` (compact, shows
name + unique id + location), and (i) change the QR payload to a raw
`tracking_id` / internal ref so the in-app scanner resolves it inline, and (ii)
add an HTML5 camera (`getUserMedia` + `BarcodeDetector`/jsQR) scanner that calls
`show_popup` on the current page — no navigation, no new window.

### 3. Individual-unit identity (what already satisfies the spec)

`Tracked Item` (`tracked_item/tracked_item.py`) already implements the core of
Part 2 §2/§3:

- unique `tracking_id` auto-generated per unit (`CARWHEEL-0001`, …) with a
  duplicate guard in `before_insert`; `barcode == tracking_id`; QR generated per
  unit; `bulk_create_tracked_items(item_code, qty, …)` creates N unique units.
- `lookup_tracked_item()` resolves by raw id, barcode, or QR URL and returns
  item name/code, `current_warehouse`, `current_status`, last transaction.

**Gap:** it uses its own `Tracked Item` doctype and does **not** yet integrate
with ERPNext's native **Serial No** (`has_serial_no` + `Serial No` doctype) or
the standard `Item Barcode` child. The task asks to "follow ERPNext's existing
Serial No / Item master functionality wherever possible" — a decision point:
either map `Tracked Item` onto ERPNext `Serial No` (preferred, avoids a parallel
identity system), or keep `Tracked Item` and reconcile it with `Serial No`.

### 4. Warehouse tracking (what already works / gaps)

- Stock Entry submit/cancel moves `current_warehouse` and appends
  `item_tracking_history` (receipt → Stores, transfer → WIP/Finished Goods) —
  **works** and is driven by real Stock Entry rows, not hardcoded data.
- Delivery Note submit marks `Delivered` (warehouse → None) — **works**.
- **Gaps:** `current_status` is coarse (`In Stock`/`Consumed`/`Delivered`); there
  is no explicit handling for *reserved / in-transit / returned / cancelled* as
  distinct statuses beyond the `in_transit` flag. "In Transit" warehouse is only
  modelled if a transfer targets a "Goods In Transit" warehouse. No link back to
  native `Stock Ledger Entry` for a canonical movement history — the app
  maintains its own history table.

---

## PART 3 — UI / Integration

- The scan popup already uses `frappe.ui.Dialog` (integrated look) — good, keep it.
- The `www/tracked_item_lookup` page is the offending "separate window"; deprecate it.
- `item_tracking` is **not surfaced in ERPNext navigation** (no Workspace /
  `desk` page shortcut for the tracker); users reach it only via the detached link.
  `barcode_shrdc` has `config/desktop.py` + `Barcode Printing` workspace; `item_tracking`
  has none.

---

## Prioritised implementation plan (not yet executed)

1. **Fix the Stock Entry UI path** — complete the item row (warehouses) in
   `scan_into_stock_entry`, rebuild the JS bundle, verify a real submit.
2. **Kill the separate window** — change QR payload to raw `tracking_id`;
   remove/deprecate `www/tracked_item_lookup`.
3. **Inline camera scanner** — add an HTML5 camera scanner (BarcodeDetector +
   jsQR fallback) as a `frappe.ui.Dialog`, reusing `show_popup`; repeated scans
   without refresh; "not found" → inline error.
4. **Wire into navigation** — add a Workspace / desk page + links from Item,
   Stock Entry, Serial No, Warehouse to the tracker.
5. **Native Serial No integration** — reconcile `Tracked Item` with ERPNext
   `Serial No` (decision needed).
6. **Warehouse status completeness** — add reserved/in-transit/returned handling,
   and derive location from `Stock Ledger Entry` rather than only the app table.
7. **Malaysia E-Invoicing layer** — TIN/BRN + SST classification fields,
   MyInvois payload preparation, status lifecycle, API client behind
   sandbox/production config; submission gated on real LHDN credentials.

See the final chat reply for the full "broken vs implemented vs external
credentials vs test steps" summary.
