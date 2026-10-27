---
name: erpnext-demo-data
description: Builds competent, fully-linked ERPNext demo/seed data (Items, BOMs, Work Orders linked to Job Cards, Suppliers/Customers/Employees, optional batches/sales/stock). Use when the user asks to create demo data, test data, sample data, seed data, or to "create data to help test" a customization.
---

# erpnext-demo-data skill — competent, linked demo data on the SANDBOX

## What this skill is for (plain English)
When we change ERPNext, the user needs realistic example data to click
through: real items, a real BOM, a real Work Order with Job Cards, real
suppliers/customers/employees. Half-linked data (a BOM pointing at an item
that doesn't exist, a Work Order with no Job Card) proves nothing. This skill
makes the seed data **complete, linked, idempotent and repeatable**.

## Default: OFF — you MUST ask first (mandatory)
Demo data is **never created by default**. Do not generate, seed or plan it unless the user has explicitly said yes.
- Include exactly one clear question in the plan/confirmation step: *"Do you want me to create demo data to test this change? (yes / no / a minimal subset)"*.
- No answer or "no" → **skip demo data entirely**; the change still ships without it.
- "Yes" → seed **only the data relevant to their issue** (their products, their document chain, the fields the change touches), and honour the conditional rules below.
- A direct user request like "create demo data to help test the changes" counts as yes for that change — still confirm scope (batches? sales? stock?) before seeding.

## Hard rules (never break)
1. **SANDBOX/TEST ONLY.** Demo data goes on the disposable test site
   (`test-sandbox`), never production. AGENTS.md rule 6 still applies.
2. **Idempotent always.** The seed must wipe its *own* docs first (prefixed
   names only) then recreate, so re-running is safe. Never delete stock/
   standard records you didn't create.
3. **Prefix everything.** Use the agreed prefix (`cx_`) or a demo prefix
   (e.g. `DEMO-`, `FG-`, `RM-`, `ST-`) so the data is easy to find and remove.
4. **ORM only.** No raw SQL. Use `frappe.get_doc(...).insert()/submit()`.
5. **Commit and verify.** `frappe.db.commit()` at the end, then print/assert
   counts so a bad run is obvious.
6. **Reversible.** Include a row for the seed in `Customisations.md` and a
   one-line rollback note (delete the prefixed docs / rerun the wipe section).

## Mandatory coverage (build the whole chain, linked)
Create these whenever building demo data, unless the user scopes it down:

1. **Items** — raw materials, WIP and finished goods.
   - Raw material (`is_stock_item=1`, group "Raw Material"), WIP items
     (`include_item_in_manufacturing=1`), finished goods.
   - Set sensible `stock_uom`, `valuation_rate`, item groups.
2. **BOMs — for every finished good AND every WIP item; they must link.**
   - WIP BOM consumes raw material(s); FG BOM consumes the WIP item; use a
     **multi-level** chain so the links are real (`use_multi_level_bom`).
   - Set `is_active=1`, `is_default=1`, submit each BOM. Only one active BOM
     per item.
3. **Work Orders that link to specific Job Cards.**
   - Create + submit a Work Order per production item against its BOM.
   - A **submitted** Work Order auto-creates Job Cards in v16. A
     *programmatic* WO insert must call `wo.get_items_and_operations_from_bom()`
     first or it has no operations (see skill `frappe-version-gotchas`).
   - Explicitly assign/verify each Job Card's `work_order`, `operation`,
     `workstation`; add `employee` rows where the user wants operator detail.
4. **Suppliers, Customers and Employees.**
   - Suppliers (with `supplier_group`), Customers (with `customer_group`,
     `territory`), Employees (with `designation`, `company`, `status=Active`).
5. **Supporting masters:** Company, Warehouses (RM/WIP/FG/Scrap/Subcontract),
   UOM/Item Groups, Price Lists, Workstations + Workstation Types, Operations.

## Conditional rules (ask, don't assume)
- **(a) Batches.** Only add batches if the user asked for item batches. Then:
  set `has_batch_no=1` on the relevant items, create `Batch` records linked to
  their item, and pass `batch_no` through Stock Entry lines / Job Cards so the
  batch actually links. Do not enable batches unasked.
- **(b) Extra data when the requirement needs it.** Add prior Sales Orders,
  opening inventory / Stock Entries, Purchase Orders, Production Plans, Quality
  Inspections — but only when the feature under test depends on them.
- **(c) Ask first if the requirement is specific.** Before seeding, offer the
  relevant optional data as a short yes/no question, e.g.:
  "Your change touches stock — should the demo data also include opening
  inventory, prior sales, and batches, or keep it minimal?" List the X/Y/Z
  options and let the user choose. Never silently add or omit material data.

## Build order (respect dependencies)
Company → Warehouses → Item Groups/UOM → Suppliers/Customers/Employees →
Workstation Type → Workstation → Operation → Items (+ Item Price) →
**BOMs (raw→WIP→FG, submit in order)** → Opening stock / batches (Stock Entry
with `batch_no`) → Work Orders (submit) → Job Cards (link employee/operation)
→ optional Sales Orders / Production Plan / Quality Inspection.

## Verify before reporting done
- Every BOM's `item` exists and each `items` child links to a real Item.
- Every Work Order has a submitted BOM and at least one Job Card whose
  `work_order` == the WO name.
- If batches were requested: every "batched" item has `has_batch_no=1`, a
  `Batch` exists, and the Stock Entry that received it carries `batch_no`.
- Print final counts (items, BOMs, WOs, JCs, parties) and the exact demo names.
- State clearly: **TEST data on `<site>` — not production.**

## Output format
1. One line: what the demo data represents (products, chain, parties).
2. Whether batches/extras are included (and confirm if it was an ask-first case).
3. The seed file path + how it runs (`bench --site <site> console < file.py`).
4. Rollback note.
5. Verification result (counts / links checked).
