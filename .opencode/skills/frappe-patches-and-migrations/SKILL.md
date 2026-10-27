---
name: frappe-patches-and-migrations
description: Writes idempotent Frappe patches, data backfills, fixture lifecycle, Data Import, and scheduler_events background jobs for ERPNext custom apps. Use when existing records must be updated, data imported, or a recurring job added.
---

# frappe-patches-and-migrations skill — patches, data, jobs

## What this skill is for (plain English)
Some changes are not just a new field — they must also **fix or fill existing
records** ("set `cx_status` to Open for every existing Tool"), **import a
spreadsheet once**, or **run on a schedule** ("email managers every Monday about
tools near end of life"). This skill covers those, safely and repeatably.

## When to use it
- New field added, and old records need a default value → **patch**.
- One-off CSV/XLSX load → **Data Import**.
- Recurring automation → **scheduler_events**.
- Fixture export/import (Custom Field, Property Setter, Workflow, Dashboard…).

## Patches (`<custom_app>/patches.txt`)
- File format uses sections: `[pre_model_sync]` and `[post_model_sync]`.
  Put data fixes in **post_model_sync** so new columns/fields already exist.
- Reference a patch either by dotted path (`myapp.patches.v1_0.set_default_status`)
  or `execute:myapp.patches.v1_0.set_default_status`.
- **Idempotent always** — running it twice must be harmless. Guard with
  `if frappe.db.exists(...)` / only touch rows still at the old value.
- Prefer the ORM (`frappe.get_all`, `doc.save()`, `frappe.db.set_value`) over raw
  `UPDATE` SQL. **AGENTS.md rule 4: no raw SQL writes on ERPNext tables.**
- **Print/`frappe.log_error` counts** for large tables and `frappe.db.commit()`
  in sensible batches so a failure is diagnosable.
- Patches are **not** un-run by rollback — record old values in the patch (e.g. a
  log doctype or a `cx_` backup field) if the change must be reversible.

## Fixture lifecycle (customizations to standard DocTypes)
- `hooks.py` `fixtures = [{"doctype": "Custom Field", "filters": [["name","like","cx\\_%"]]}]`.
- `bench --site <site> export-fixtures` writes `fixtures/*.json`.
- Every hand-written entry needs an explicit `"name"` key (e.g.
  `"Sales Order-cx_tool"`) or import fails with `KeyError: 'name'`.
- `bench migrate` is what applies fixtures; verify after a fresh install.
- Uninstall does **not** remove custom fields on standard DocTypes — plan a
  reverse patch or `bench remove-custom-field` in the rollback note.

## Data Import (one-off)
Use **Data Import** for a spreadsheet load: map columns, download the template,
import as a background job, then check the Error/Mutation Log. Do not write a
one-off raw-SQL script instead.

## Background jobs (`scheduler_events` in `hooks.py`)
- Keys: `all`, `hourly`, `daily`, `weekly`, `monthly`, `cron`.
- Point to a dotted function: `"daily": ["myapp.tasks.check_tool_life"]`.
- Jobs must be **idempotent** and **cheap** — enqueue heavy work with
  `frappe.enqueue(...)` rather than doing it inline.
- Never `commit()` inside a scheduled job in a way that swallows errors; let
  failures reach the Error Log so they are visible.
- Guard against missing custom fields (`frappe.get_meta(dt).has_field(...)`) so
  the job still runs on a site where the app isn't installed.

## Version traps
Read the installed source before relying on patch/scheduler behaviour; section
headers and `bench migrate` ordering differ across v14/v15/v16. See skill
`frappe-version-gotchas`. Always `bench version` first (AGENTS.md rule 10).

## Testing template
- Run the patch twice → second run changes 0 rows, no error.
- Add a unit test that seeds old-format data, runs the patch function, asserts the
  new value.
- For a scheduler job, call the function directly in a test and assert it is safe
  when there is nothing to do.
