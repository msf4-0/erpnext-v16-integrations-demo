---
name: frappe-doctype-builder
description: Safe, version-aware patterns for creating or modifying Frappe/ERPNext DocTypes, custom fields, property setters, client/server scripts, doc_events, child tables and form UI. Use whenever a request adds or changes a DocType, field, validation, permission, or form behavior.
---

# SKILL: Frappe/ERPNext DocType Creation and Modification
You are acting as a senior Frappe framework developer. This skill governs every time you create a new DocType or modify an existing one (standard or custom). Follow it exactly. When in doubt, choose the least invasive mechanism and ask before proceeding.

## 1. FIRST, CLASSIFY THE CHANGE
Before writing anything, determine which of these five categories the request falls into, and say so explicitly to the user:

| Category | Example | Mechanism |
|---|---|---|
| A. New field on an existing DocType | "Track drawing number on Sales Order" | Custom Field (fixture) |
| B. Change field behavior/layout on existing DocType | "Make discount mandatory", "hide a field for a role" | Property Setter (fixture) |
| C. New business logic on an existing DocType | "Block Job Card submit if tool life exceeded" | `doc_events` hook in custom app, or Server Script |
| D. Brand-new concept that doesn't exist yet | "Track dies/molds" | New Custom DocType inside the custom app |
| E. New UI behavior only, no schema change | "Auto-fill field, show/hide section" | Client Script (fixture or app JS) |

Never default to "just create a new DocType" — that's category creep. Prefer A → B → E → C → D in that order of invasiveness.

## 2. GROUND RULES (apply to all categories)
1. All artifacts live in the user's custom app (confirm the app name first; suggest `bench new-app <name>` if none exists).
2. Prefix every custom DocType name, field name, and naming series with the agreed prefix (ask; default `cx_`). Example: field `cx_tool`, DocType `Tool`.
3. Never hand-edit files inside `apps/erpnext` or `apps/frappe`. If a standard `.py` controller needs extra logic, use `doc_events` in `hooks.py`, not a direct edit.
4. Every schema change must be captured as a **fixture** (Custom Field, Property Setter, Custom DocType JSON) so it can be version-controlled and re-deployed with `bench migrate`, not just clicked into existence via Customize Form and left in the database only.
5. Every change needs: (a) a one-line rollback note, (b) a Frappe unit test, (c) a plain-English description for the user.
6. Check the installed Frappe/ERPNext version before using any version-specific API (ask if unknown, or run `bench version`).
7. Never touch permissions in a way that widens System Manager-only access to sensitive doctypes (Payment Entry, GL Entry, etc.) without explicit confirmation.

## 3. CREATING A NEW DOCTYPE — CHECKLIST
Walk through every item. Ask the user only for what you can't infer.

**3.1 Identity**
- Name (singular, Title Case, prefixed if it risks clashing, e.g. `Tool` vs `Tool Log`)
- Module (create a new module in the custom app, or use an existing one — ask). **The module name must scrub to something DIFFERENT from the app name** (e.g. app `my_tooling` → module `Tooling`, not `My Tooling`): the controller import path is `{app}.{module}.doctype.{dt}.{dt}`, so a same-named module makes the controller unimportable. Learned 2026-09-29.
- Is it a **submittable** document (has Draft/Submitted/Cancelled states) or a simple master/setting record?
- Is it a **child table** (used inside another DocType's grid) or a standalone (top-level, has its own list view)?
- Naming rule: auto-increment, field-based, naming series (`TOOL-.#####`), or Prompt. If you omit `autoname`/`naming_rule`, Frappe falls back to random-hash names — fine for demos, confirm for production.

**3.2 Fields**
For each field ask/derive: label, fieldname (snake_case), fieldtype (Data, Link, Select, Table, Currency, Int, Check, Attach, etc.), mandatory?, unique?, read-only?, default value, depends_on (conditional visibility), fetch_from (auto-pull from a linked doc), in_list_view, in_standard_filter.
- If it links to a standard doctype (e.g. `Link` to `Workstation` or `Item`), confirm the exact target doctype name.
- If it's a child table, define the child DocType first (its own fields, no permissions needed — inherits parent's).

**3.3 Behavior**
- Validations (what must be true before save/submit — write as plain rules, then as `validate()` logic)
- Calculated/derived fields (e.g. `cx_shots_remaining = cx_life_limit - cx_shots_used`)
- What happens on submit / cancel / on_update — does it need to update another doctype (e.g. increment a counter on a linked Tool when a Job Card is submitted)?
- Creating downstream docs: in v16 a submitted Work Order auto-creates its Job Cards, so a custom doc that makes a WO should NOT call `make_job_card` — just build+submit the WO and stamp the Job Cards it created. A **programmatic** WO insert must call `wo.get_items_and_operations_from_bom()` first or it has no operations (see skill `frappe-version-gotchas`).
- Any scheduled/background job needed (e.g. daily check for tools nearing end of life)?

**3.4 Permissions**
- Which roles: Read / Write / Create / Delete / Submit / Cancel / Amend / Print / Report / Export / Import?
- Role-level or user-level restrictions (e.g. only see records for their own workstation)?
- Should it respect "if owner" restrictions?

**3.5 UI/UX**
- List view columns, default sort, default filters
- Dashboard: should it show a "Connections" tab linking to related docs (e.g. Tool → Job Cards that used it)?
- Print format needed?
- Quick entry vs full form?

**3.6 Output artifacts for a new DocType**
- `<custom_app>/<module>/doctype/<doctype_name>/<doctype_name>.json` (schema)
- `<doctype_name>.py` (controller: validate, on_submit, etc.). **Must define `class <DocType>(Document)`** (e.g. `class Tool(Document)`) — a controller file with only bare functions makes `get_controller()` raise `ImportError`, and `remove_orphan_doctypes()` will then silently DELETE the DocType on the next `bench migrate` even though install reported 100%. If a freshly installed doctype vanishes after migrate, check this first. Learned 2026-09-29.
- `<doctype_name>.js` (form script: client-side behavior)
- Test file `test_<doctype_name>.py` with at least: create, mandatory field enforcement, one business rule, permission check
- Entry in `custom_app/fixtures/` if you want it exportable, OR rely on the module itself being the source of truth (new DocTypes in your own app don't need to be fixtures — only customizations to *standard* doctypes do)
- Patch entry in `patches.txt` only if data migration is needed (e.g. backfilling existing records)

## 4. MODIFYING AN EXISTING (STANDARD) DOCTYPE — CHECKLIST

**4.1 Adding a field → Custom Field**
- Define: dt (target doctype), fieldname (prefixed), label, fieldtype, insert_after (which existing field it goes after), mandatory, depends_on, fetch_from.
- Export as fixture: add `{"doctype": "Custom Field", "filters": [["dt", "in", [...]]]}` to `hooks.py`'s `fixtures` list, then `bench --site <site> export-fixtures`.
- Every hand-written `fixtures/custom_field.json` entry needs an explicit `"name"` key in `"<Dt>-<fieldname>"` format (e.g. `"Job Card-cx_tool"`) — without it fixture import dies with `KeyError: 'name'`. Learned 2026-09-29.
- Never add a field with the same name as a possible future core field — always prefix.

**4.2 Changing existing field behavior → Property Setter**
- Examples: make a core field mandatory, change its label, hide it for certain roles via `depends_on`, change `read_only`, change `options` on a Select field.
- Same fixture export process as Custom Field.
- Never use a Property Setter to change a field's fieldtype on a standard doctype — that's fragile across upgrades; prefer a new Custom Field instead.

**4.3 Adding business logic → `doc_events` (preferred) or Server Script (if no-code is required)**
```python
# custom_app/hooks.py
doc_events = {
    "Job Card": {
        "validate": "custom_app.custom_app.events.job_card.validate_tool_life",
        "on_submit": "custom_app.custom_app.events.job_card.increment_tool_shots",
    }
}
```
```python
# custom_app/custom_app/events/job_card.py
import frappe

def validate_tool_life(doc, method):
    if not doc.cx_tool:
        return
    tool = frappe.get_doc("Tool", doc.cx_tool)
    if tool.cx_shots_used + doc.cx_shots >= tool.cx_life_limit:
        frappe.throw(f"Tool {tool.name} will exceed its life limit ({tool.cx_life_limit} shots).")

def increment_tool_shots(doc, method):
    if doc.cx_tool and doc.cx_shots:
        frappe.db.set_value("Tool", doc.cx_tool, "cx_shots_used",
            frappe.db.get_value("Tool", doc.cx_tool, "cx_shots_used") + doc.cx_shots)
```
- Always call the minimum necessary; never override the whole `validate()`/`on_submit()` of the core class unless using `override_doctype_class`, and if you do, always call `super()`.
- Server Scripts (DocType Event / API / Scheduler type) are acceptable for simple, low-risk logic that non-developers may need to adjust later, but prefer `doc_events` in code for anything tested and version-controlled.

**4.4 Client-side only changes → Client Script or `<doctype>.js` in the custom app hooking `frappe.ui.form.on`**
```js
frappe.ui.form.on('Job Card', {
    cx_tool: function(frm) {
        if (frm.doc.cx_tool) {
            frappe.db.get_value('Tool', frm.doc.cx_tool, ['cx_shots_used', 'cx_life_limit'], (r) => {
                frm.set_df_property('cx_shots', 'description',
                    `Tool has ${r.cx_life_limit - r.cx_shots_used} shots remaining`);
            });
        }
    }
});
```

**4.5 Workflow changes**
- If the request needs approval states (e.g. "Tool maintenance must be approved before reuse"), use the Workflow doctype (states + transitions + roles) rather than hardcoding status fields — it's upgrade-safe and fixture-exportable.

## 5. VERSION-SAFE PATTERNS (apply always)
- **Read the INSTALLED source before calling any core method whose signature you are not certain of** (read-only grep in the container). See skill `frappe-version-gotchas` for the v16 traps that have already bitten us (`frappe.defaults.get_default`, `make_job_card` signature, programmatic Work Order needing `get_items_and_operations_from_bom`, BOM `with_operations`).
- Wrap any field access that might not exist yet with `doc.get("fieldname")` not `doc.fieldname` when the field is optional/custom.
- When hooking into core methods, use `doc_events`, not monkey-patching the class in memory.
- Use `frappe.get_meta(doctype).has_field(fieldname)` to check before assuming a custom field exists, in case the app isn't installed on every site.
- Guard scheduler jobs and patches to be idempotent (safe to run twice).
- Pin dependency on ERPNext version in the custom app's `hooks.py` `required_apps` if using version-specific fields.

## 6. TESTING TEMPLATE (generate for every change)
```python
# custom_app/custom_app/doctype/tool/test_tool.py
import frappe
import unittest

class TestTool(unittest.TestCase):
    def test_shot_limit_blocks_job_card(self):
        tool = frappe.get_doc({
            "doctype": "Tool", "tool_name": "Test Die",
            "cx_life_limit": 100, "cx_shots_used": 95
        }).insert()
        jc = frappe.get_doc({
            "doctype": "Job Card", "cx_tool": tool.name, "cx_shots": 10,
            # ...other mandatory Job Card fields
        })
        self.assertRaises(frappe.ValidationError, jc.insert)
```

> `doc.validate()` calls only the controller method — `doc_events` hooks fire
> only via `run_method()` (the save/submit path). In tests, assert hook behavior
> with `jc.run_method("validate")`, `jc.save()`, or `jc.submit()` — never bare
> `jc.validate()`, or the hook silently never runs and the test misleads.
> Learned 2026-09-29.

## 7. DEPLOYMENT SEQUENCE (always show this before applying to production)
1. `bench --site <site> backup --with-files`
2. Apply on a dev/staging site first
3. `bench --site <site> migrate`
4. `bench --site <site> run-tests --app <custom_app>`
5. Show the user a diff / summary of every file changed or created
6. Get explicit "approved" before touching production
7. On production: repeat backup → migrate → smoke test → monitor error log

## 8. WHAT TO ASK, MINIMALLY (don't re-run the full interview here — assume Phase 0–2 context already exists from the main interview skill; only ask what's specific to the DocType/field itself)
- "Is this a brand-new record type, or does it belong on an existing document?" (routes to category A–E)
- "Which document triggers or uses this data day-to-day?"
- "Who edits it, and does it need an approval step?"
- "Any field that should auto-calculate or auto-block based on another value?"
- Confirm the draft schema back to the user in a plain table before generating code.

## 9. OUTPUT FORMAT WHEN RESPONDING TO THE USER
1. One-paragraph plain-English description of what will be built
2. The classification (A–E) and why
3. The field/DocType table
4. The files to be created/changed
5. The rollback note
6. Wait for "approved" before writing files

## 10. REPO SAFETY TIE-IN (from AGENTS.md — non-negotiable)
- Never edit `apps/erpnext/` or `apps/frappe/` (read-only reference only).
- Order of invasiveness: Custom Field → Property Setter → Client/Server Script → `doc_events` in `hooks.py` → new custom DocType → last-resort `override_doctype_class` / `override_whitelisted_methods` with `super()`.
- No raw SQL writes on ERPNext tables. No rename/delete of standard fields/doctypes.
- No destructive commands (`bench reinstall`, `drop`, `bench migrate --skip-failing`, bulk delete) without explicit confirmation.
- Sequence: backup → dev/staging → migrate → tests → diff → approval → production. Every change idempotent + reversible with rollback note.
- Namespace all custom fields/doctypes with agreed prefix (default `cx_`).
- Before creating anything, check whether standard ERPNext already provides it (Manufacturing Settings, Production Plan options, existing fields). Prefer configuration over customization.
- Respect installed version (v14/v15/v16 via `bench version`). Custom app `custom=0` inside app; standard customizations as fixtures filtered by prefix.
