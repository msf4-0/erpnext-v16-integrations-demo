---
name: erpnext-production-workflow
description: MTO/MTS ERPNext document-chain and manufacturing knowledge (BOM, Production Plan, Work Order, Job Card, Stock Entry, make_* methods, status transitions, pitfalls). Use when planning or explaining manufacturing/production logic.
---

# erpnext-production-workflow skill — MTO/MTS doctype chain knowledge

## What this skill is for (plain English)
ERPNext moves a factory order through a fixed chain of documents. Knowing this
chain (and which document creates the next one) is how we decide where a new
field, rule, or report belongs — and how to test it without corrupting stock or
accounts.

## The document chains
Chains: Selling Lead→Opportunity→Quotation→Sales Order→Delivery Note→Sales Invoice. Buying: Material Request→RFQ→Purchase Order→Purchase Receipt→Purchase Invoice. Manufacturing: Item, BOM (multi-level, operations, scrap, by-products), Routing, Operation, Workstation/Type, Production Plan (MRP, material shortages → MR/PR/PO), Work Order (Draft→In Process→Completed/Stopped), Job Card (per operation/workstation; time logs, operators, sequence; Started→Work in Progress→Completed), Stock Entry types (Material Transfer for Manufacture, Manufacture, Material Consumption for Manufacture / backflush), Downtime Entry, Quality Inspection, Subcontracting, Manufacturing Settings. Stock: Warehouse (RM/WIP/FG/Scrap), Bin, Stock Ledger Entry, Pick List, Batch, Serial No, Reorder rules. Delivery: Pick List, Packing Slip, Delivery Note, Shipment.
Typical: Sales Order → Production Plan → Material Requests/POs → Work Orders → Job Cards → Stock Entries → FG → Delivery Note → Invoice.
Linked-doc methods: `erpnext.manufacturing.doctype.production_plan.production_plan.make_work_order`, `...make_material_request`, `erpnext.manufacturing.doctype.work_order.work_order.make_stock_entry`, Job Card creation from Work Order operations. Status transitions: SO Submitted→To Deliver/Bill; WO Draft→Submitted→In Process→Completed→Stock Entry submitted; Job Card Open→Work in Progress→Completed.
Pitfalls: backflush vs explicit WIP transfer; over/under-production tolerance (Manufacturing Settings); capacity vs due-date planning; partial deliveries; SO amendment after WO started; QC holds blocking DN/invoice. **v16**: Work Order submit auto-creates its Job Cards ONLY if the WO already has operations (programmatic insert must call `wo.get_items_and_operations_from_bom()` first); a BOM keeps operations only with `with_operations=1` and needs at least one raw item; `make_job_card`'s 2nd arg is the operations list, not a `{"company": ...}` dict. See skill `frappe-version-gotchas`.
