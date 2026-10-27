# Customisations — registry of every customisation added to this workspace

> **Single source of navigation for custom work.** Every time an agent adds,
> edits, or removes a customisation in this workspace, it MUST add or update a
> row in the tables below. This file is how a human finds "what did we change,
> where does it live, and how do I roll it back" without grepping the tree.
>
> Keep it factual and current. One row per customisation.

## What counts as a customisation

Anything that is not stock ERPNext/Frappe v16:

- New custom **DocType** / child table (lives in a custom app under `repos/<app>`)
- **Custom Field** / **Property Setter** on a standard DocType (fixtures)
- **Client Script** / **Server Script**
- **doc_events** hooks in a custom app's `hooks.py`
- **Reports**, **print formats**, **workspaces**, **dashboards**, number cards
- **Workflows** / permission changes
- **Patches** / data backfills
- Any new file added outside `apps/erpnext` and `apps/frappe`

## Custom apps in this workspace

| App | Path | Source | Installed on site? | Notes |
|---|---|---|---|---|
| `custom_manufacturing` | `repos/custom_manufacturing` | local app (bench new-app) | No — sandbox was rebuilt fresh (clean base v16); reinstall on demand | Module folder `process_manufacturing` (differs from app name on purpose). Custom Metal Fab Process Master. |
| `chat_widget` | `chat_widget` | local app | Not yet installed anywhere | **PROTECTED — exempt from every rollback (see policy below).** Standalone AI chatbot: `/chatbot` page, floating widget (website + Desk), Chatbot Settings. |

## Standing rollback policy (human-ordered)

**When rolling back, the ONLY thing that is never rolled back is the chatbot
(`chat_widget`).** Enforced in `sandbox/scripts/rollback-app.sh`: `KEEP`
defaults to `chat_widget`, single-app removal of it is refused unless a human
sets `FORCE_CHATBOT_ROLLBACK=1`, and every rollback report ends with a
`CONFIRMED: chat_widget (chatbot) preserved` line. The agent must quote that
confirmation in its reply after any rollback — no silent rollbacks.

## Customisations

| # | Date | Kind (A–E) | Target DocType / Object | App + file path | Rollback tier | Status |
|---|---|---|---|---|---|---|
| 1 | 2026-10-02 | D | `Manufacturing Process Master` (new DocType) | `custom_manufacturing/process_manufacturing/doctype/manufacturing_process_master/` | 2 | Installed |
| 2 | 2026-10-02 | D | `Process Stage` (new child DocType) | `custom_manufacturing/process_manufacturing/doctype/process_stage/` | 2 | Installed |
| 3 | 2026-10-02 | A | `Item.cx_process_master` | `custom_manufacturing/fixtures/custom_field.json` | 2 | Installed |
| 4 | 2026-10-02 | A | `BOM.cx_process_master` | same | 2 | Installed |
| 5 | 2026-10-02 | A | `Work Order.cx_process_master` | same | 2 | Installed |
| 6 | 2026-10-02 | A | `Production Plan Item.cx_process_master` | same | 2 | Installed |
| 7 | 2026-10-02 | A | `Work Order Operation.cx_stage_type` / `cx_supplier` / `cx_program_no` | same | 2 | Installed |
| 8 | 2026-10-02 | A | `Job Card.cx_process_master` / `cx_stage_type` / `cx_supplier` / `cx_inspection_result` / `cx_rejected_qty` / `cx_rework_qty` / `cx_rework_reason` | same | 2 | Installed |
| 9 | 2026-10-02 | C | Work Order `before_validate` → sync stages to operations | `.../events/work_order.py` + `hooks.py` | 1 | Installed |
| 10 | 2026-10-02 | C | Job Card `before_validate` → stamp stage type/supplier | `.../events/job_card.py` + `hooks.py` | 1 | Installed |
| 11 | 2026-10-02 | C | Delivery Note `before_submit` → block until production + QC complete | `.../events/delivery_note.py` + `hooks.py` | 1 | Installed |
| 12 | 2026-10-02 | C | Whitelisted API `apply_process_master_to_work_order` | `.../process_manufacturing/api.py` | 2 | Installed |
| 13 | 2026-10-02 | E | Form script — Process Master + Work Order | `.../public/js/*.js` + `hooks.py` `doctype_js` | 2 | Installed |
| 14 | 2026-10-02 | — | Script Report `Manufacturing Load And Subcontracting` | `.../report/manufacturing_load_and_subcontracting/` | 2 | Installed |
| 15 | 2026-10-02 | — | Workspace `Manufacturing Process` | `.../workspace/manufacturing_process/` | 2 | Installed |
| 16 | 2026-10-02 | — | Print Format `Process Sheet` (Work Order) | `.../print_format/process_sheet/` | 2 | Installed |
| 17 | 2026-10-02 | — | Number Cards `Active Process Masters`, `Open Rework Job Cards` | `.../number_card/` | 2 | Installed |
| 18 | 2026-10-02 | — | Dashboard Chart `Outsourced vs In-house Job Cards` | `.../dashboard_chart/` | 2 | Installed |
| 19 | 2026-10-02 | — | Demo data (SANDBOX ONLY) `demo_data.py` | `.../process_manufacturing/demo_data.py` | 2 | Sandbox only |

Legend — **Kind** (skill `frappe-doctype-builder`): A = Custom Field · B = Property
Setter · C = doc_events/logic · D = new Custom DocType · E = Client Script.
**Rollback tier** (skill `erpnext-safe-change`): 1 = disable · 2 = remove · 3 =
restore backup · 4 = full base rollback.

### Demo / test data (sandbox `frontend` only — NOT production)
Seed via `bench --site frontend execute custom_manufacturing.process_manufacturing.demo_data.create_demo_data`;
remove with `...demo_data.wipe_demo_data`. Creates `DEMO-` prefixed items, BOMs,
Process Master `CX-MPM-00001`, Work Order, 6 Job Cards, opening stock, and a
prior Sales Order. Rollback: run `wipe_demo_data`.

## Files to remove to return to base ERPNext v16

The workspace must remain **stock ERPNext/Frappe v16** apart from the
customisations listed above. To strip everything back to base:

1. Run `sandbox/scripts/rollback-app.sh --all` (`KEEP` defaults to
   `chat_widget`, so the chatbot survives; name other apps in `KEEP=` to spare
   them too), or manually: uninstall each non-core app **except `chat_widget**,
   delete its `repos/` tree,
   drop leftover `Custom Field`/`Property Setter`/`Client Script` rows, then
   `bench migrate`.
2. Delete the corresponding rows above and the app's row in
   "Custom apps in this workspace" (never the `chat_widget` row).
3. Verify: `list-apps` shows `frappe` + `erpnext` + `chat_widget`,
   `git -C apps/erpnext status --short` and `git -C apps/frappe status --short`
   are empty.
4. Confirm in your reply: quote the script's
   `CONFIRMED: chat_widget (chatbot) preserved` line.

For this app specifically:
`bench --site <site> uninstall-app custom_manufacturing` then remove
`repos/custom_manufacturing`. First run `demo_data.wipe_demo_data` to clear the
SANDBOX demo records, and note that submitted stock docs (BOMs, Stock Entry)
must be cancelled before the app's records can be deleted.

See skill `erpnext-safe-change` → **Tier 4 — full rollback to base ERPNext**.
