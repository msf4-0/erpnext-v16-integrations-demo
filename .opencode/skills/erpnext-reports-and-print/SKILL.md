---
name: erpnext-reports-and-print
description: Builds Script/Query Reports, Dashboard Charts, Dashboards, and Jinja print formats in ERPNext. Use for report, chart, dashboard or printable-document requests. Workspaces and number cards live in erpnext-dashboards-workspaces.
---

# erpnext-reports-and-print skill — Script/Query Reports, Dashboard Charts, Jinja print formats

## What this skill is for (plain English)
Use it when someone asks for "a report of …", "a chart of …", or "a printable
document that looks like …". These are the outputs people actually look at, so
they must respect permissions and not be slow on a big database.

## When NOT to use it
- Workspaces, number cards, dashboards and custom HTML blocks → use skill
  `erpnext-dashboards-workspaces` (this skill only wires a chart into a dashboard).
- Exporting raw data once → the built-in Data Import/Export tools, not a report.

## Query Report (fast, SQL)
Files in the custom app: `report/<report_name>/<report_name>.json` + `.py` + `.js`.
- `.json` declares the report, its doc_type, and the filter fields.
- `.py` holds the SQL with `%(filter)s` placeholders and a `columns` list.
- `.js` holds `frappe.query_reports["<name>"] = { filters: [...] }`.
Rules: **never write to standard tables**; always filter by company/date;
paginate or cap rows; keep columns index-friendly; test with real filters.

## Script Report (Python logic)
Same file trio, but `.py` exposes `execute(filters)` returning
`(columns, data, message, chart)` — use it when the logic is too complex for
plain SQL or must reuse Python helpers. Keep it read-only.

## Print Format (Jinja)
- Duplicate the closest standard format, rename with the agreed prefix, e.g. `CX-`.
- Jinja fields (`{{ doc.customer }}`), custom CSS for letterhead/branding.
- Control visibility per role; never print internal cost fields to customers.
- Version it in the custom app; add fixtures filtered by the `cx_` prefix.

## Test + verify (required)
Run with real filter values, confirm columns/filters behave, and open it as a
non-System-Manager role to prove permissions. For a dashboard chart, verify the
numbers against the underlying list view before handing it over.
