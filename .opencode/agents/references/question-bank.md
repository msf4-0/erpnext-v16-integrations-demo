# question-bank.md — hardcoded, do not remove any question (wording may be polished)

> **Question formatting (MANDATORY):** present each question as its own block — number + question on its own line, each option (`a) `, `b) `, `c) `, `d) `) on its own line, one blank line between question blocks. Never write a running paragraph and never inline `a) ... b) ... c) ...` on one line.
>
> ```
> 1.2. How would you like to solve issue X?
> a) Solution A
> b) Solution B
> c) Solution C
> d) I'm not sure — explain the options first
> ```

## Phase 0 – Environment (ask first)
0.1 Which ERPNext/Frappe version is installed (v14 / v15 / v16 / not sure → I'll run `bench version`)? [doctypes: all — determines available features]
0.2 Is this a development/staging site, or production? Do you have a recent backup? [doctypes: all — determines deploy path]
0.3 Is there already a custom app for your changes? (name / no, please create one / not sure) [doctypes: all custom artefacts]
0.4 Preferred prefix for custom fields and doctypes (default `cx_`)? [doctypes: all custom fields/doctypes]
0.5 Is the site self-hosted, Frappe Cloud, or docker? (affects how we deploy custom apps) [doctypes: deployment]

## Phase 1 – The Problem (goal in plain words)
1.1 In one or two sentences, what is going wrong or missing today in your production process? [doctypes: TBD]
1.2 Who feels the pain most (planner, sales, store keeper, shop-floor supervisor, operator, accountant, management)? [doctypes: roles/permissions]
1.3 What would "fixed" look like? (e.g., fewer late deliveries, no material shortages, accurate costing, visibility of job status) [doctypes: reports/dashboards]
1.4 Is this a: new information you need to record / a new rule or validation / an automation / a report or dashboard / a new document type / a change to an existing document / not sure? [doctypes: Custom Field / DocType / Workflow / Report]

## Phase 2 – What You Make (item and BOM structure)
2.1 Do you make to order (only after a customer order), make to stock, or a mix? [doctypes: Sales Order, Production Plan, Work Order]
2.2 Is production discrete (units), process/batch (recipes, yields), or both? [doctypes: Item, BOM, Batch]
2.3 Do your products have multi-level BOMs (sub-assemblies)? Do you use item variants? [doctypes: BOM, Item Variant]
2.4 Do BOMs have operations and routing, and do you track scrap, by-products, or yield loss? [doctypes: BOM, Routing, Operation]
2.5 Any subcontracting (sending materials to a supplier for processing)? [doctypes: Subcontracting / Purchase Order]
2.6 Do you use batches, serial numbers, or expiry dates for raw material or finished goods? [doctypes: Batch, Serial No]

## Phase 3 – Selling (order intake)
3.1 What starts production: a confirmed Sales Order, a Quotation, a forecast, or a manual decision? [doctypes: Sales Order, Quotation, Production Plan]
3.2 Does a Sales Order need extra information for production (drawings, specs, colour, dimensions, priority, customer PO number)? List each item and its data type. [doctypes: Sales Order, Custom Field]
3.3 How is the delivery date decided (manual, based on lead time, based on capacity)? Should the system warn when the date is unachievable? [doctypes: Sales Order, Production Plan]
3.4 Are partial deliveries allowed? Can a Sales Order be amended after production starts? [doctypes: Sales Order, Delivery Note]
3.5 Do different customers have different rules (special packaging, labelling, approval)? [doctypes: Customer, Sales Order]

## Phase 4 – Purchasing and Stock
4.1 When raw materials are short, what should happen: manual decision, auto Material Request, or auto Purchase Order? [doctypes: Material Request, Purchase Order, Production Plan]
4.2 Do you use reorder levels or safety stock? Any preferred suppliers per item? [doctypes: Item Reorder, Item Default]
4.3 Which warehouses exist (Raw Material, WIP, Finished Goods, Scrap, per-site)? Should raw materials be moved to WIP before production or consumed automatically at completion (backflush)? [doctypes: Warehouse, Stock Entry, Manufacturing Settings]
4.4 Is there a QC check on incoming material (Quality Inspection on Purchase Receipt)? [doctypes: Quality Inspection, Purchase Receipt]
4.5 Do you allow production with insufficient stock, or should it be blocked? [doctypes: Work Order, Stock Entry]

## Phase 5 – Planning and Scheduling
5.1 Who creates the plan and how often (daily, weekly, per order)? Do you use Production Plan / MRP today? [doctypes: Production Plan]
5.2 Do you plan by capacity (machine or workstation hours, shifts, holidays) or just by due date? [doctypes: Workstation, Routing]
5.3 List your workstations/machines: name, type, hourly rate, working hours, capacity, and whether any are shared. [doctypes: Workstation, Workstation Type, Operation]
5.4 Should the system auto-schedule Work Orders (planned start/end) or does a human set them? [doctypes: Work Order]
5.5 How are priorities handled (rush orders, customer priority, earliest due date)? [doctypes: Work Order, Sales Order]

## Phase 6 – Shop Floor Execution (Work Order and Job Card)
6.1 Are operations done in strict sequence or can some run in parallel? [doctypes: Job Card, Routing]
6.2 Who records work (operator on a tablet, supervisor, nobody today)? Do you need operator-level time logs? [doctypes: Job Card, Job Card Time Log]
6.3 What must be captured per Job Card: quantity completed, rejected/scrap qty, reasons, machine readings, photos, notes, downtime? [doctypes: Job Card, Downtime Entry]
6.4 Do you need quality inspection at specific operations? What happens on failure (rework, scrap, hold)? [doctypes: Quality Inspection, Job Card]
6.5 Do you need status alerts (delay, machine down, material missing)? To whom and by which channel (email, system notification, WhatsApp/Slack)? [doctypes: Notification]
6.6 Is over-production or under-production allowed? By how much? [doctypes: Work Order, Manufacturing Settings]

## Phase 7 – Delivery and Invoicing
7.1 What links finished goods to delivery: Pick List, Packing Slip, Delivery Note directly? [doctypes: Pick List, Packing Slip, Delivery Note]
7.2 Do you need packaging or shipment details, e.g., carton counts, weights, tracking numbers? [doctypes: Packing Slip, Shipment]
7.3 Is invoicing triggered by delivery or by the sales order (advance/milestone)? [doctypes: Sales Invoice, Delivery Note]
7.4 Should the Delivery Note be blocked until production and QC are complete? [doctypes: Delivery Note, Quality Inspection]

## Phase 8 – Users, Data and Output
8.1 Which roles should see, create, edit, submit or cancel this new data or document? (list roles) [doctypes: permissions on affected doctypes]
8.2 Should the new data appear on print formats (Sales Order, Delivery Note, Job Card sheet)? Which ones? [doctypes: Print Format]
8.3 What reports, list views, or dashboard charts do you need (e.g., OTIF, WIP status, machine utilization, material shortage)? Which filters and columns? [doctypes: Report, Dashboard Chart]
8.4 Do you have existing data to migrate or import? [doctypes: Data Import]
8.5 Any integration with external systems (barcode scanners, IoT machines, e-commerce, accounting)? [doctypes: integrations]

## Phase 9 – Change Type Discovery (agent fills this in from earlier answers, then confirms with the user)
9.1 Confirm which of these apply: New Custom Field / New Custom DocType / New Child Table / Validation Rule / Auto-creation of linked documents / Workflow (states and approvals) / Custom Report / Print Format / Notification / Dashboard / Permission change.
9.2 Confirm which standard doctypes are touched (read only vs modified).

## Phase 10 – Confirmation
10.1 Present the Requirements Spec and Impact Matrix. Ask: "Is anything missing, wrong, or unnecessary?"
10.2 Ask what the acceptance test is: "Give me one real example that should work when we're done."
10.3 Ask: "Do you want me to create demo data to test this change? (yes / no / a minimal subset)" — demo data is OFF BY DEFAULT; seed only on an explicit yes, scoped to the user's issue (skill `erpnext-demo-data`). No answer or "no" → skip demo data.
10.4 Only proceed to implementation on the user's explicit "approved".
