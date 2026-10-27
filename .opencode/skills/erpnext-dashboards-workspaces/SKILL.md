---
name: erpnext-dashboards-workspaces
description: Builds ERPNext Workspaces, Dashboards, Dashboard Charts, Number Cards, and Custom HTML Blocks (the landing pages and KPI tiles users see first). Use on requests for a workspace, home/landing page, dashboard, KPI tile, number card, or chart widget.
---

# erpnext-dashboards-workspaces skill — Workspaces, Dashboards, Charts, Number Cards

## What this skill is for (plain English)
This is about the **screens people open first**: the icon landing pages
(Workspaces) and the KPI tiles/charts on them (Dashboards, Dashboard Charts,
Number Cards). Example: a "Tooling" workspace with a Number Card "Dies nearing
end of life" and a chart "Shots per workstation".

## When to use it
- New Workspace / shortcut / card layout.
- New Dashboard, Dashboard Chart, or Number Card.
- Custom HTML Block (dashboards only, not print).
Use skill `erpnext-reports-and-print` when the chart is backed by a report/format.

## Concepts (build blocks, smallest → biggest)
- **Number Card** — one KPI tile. Types: *Document Type* (count/sum of a doctype),
  *Report* (a report's first row), *Custom* (a whitelisted method you write).
  Fields: label, document_type/report_name, function (Count/Sum/Average),
  aggregate_function_based_on, filters_json, `show_percentage_stats`.
- **Dashboard Chart** — a graph. Types: Count / Sum / Average / Custom.
  A Custom chart is backed by a **Dashboard Chart Source** (a report or a
  whitelisted Python method returning labels + datasets). Fields: chart_type,
  document_type, based_on, group_by_type, timespan/time_interval, filters_json.
- **Dashboard** — a named collection of charts (with a shared company/date
  filter). Add charts automatically from a doctype's `dashboard` in the JSON, or
  manually to a Dashboard doc.
- **Workspace** — the landing page. `content` is a JSON string of blocks
  (header, paragraph, spacer, number_card, chart, shortcut, quick_list, card),
  plus `links` (card breaks → doctype/report/page) and `shortcuts`.
- **Custom HTML Block** — reusable HTML/JS snippet for a Dashboard/Workspace.

## How to build (version-controlled, not click-only)
1. Draft the layout in the UI if it's easier, then **export** it so it is code.
2. Workspaces live as app files:
   `<custom_app>/<module>/workspace/<workspace>/<workspace>.json`
   (`"is_standard": 1`, module = your app module, naming scrubbed distinct from
   the app name per `frappe-doctype-builder`).
3. Dashboard / Dashboard Chart / Number Card / Custom HTML Block are DocTypes:
   keep them as **fixtures** filtered by the agreed `cx_` prefix, then
   `bench --site <site> export-fixtures`.
4. Set `module` = your custom app module, and `is_standard`/owner consistently,
   so `bench migrate` syncs them instead of leaving DB-only orphans.
5. Prefix every custom label and fixture name with `cx_` (default) to survive
   ERPNext upgrades.

## Version traps (read installed source first)
- Workspace `content` is a **JSON string**, not a list — malformed JSON makes the
  whole page blank. Validate it before deploying.
- Chart/card field names changed across v14/v15/v16 (`filters_json`,
  `timespan`, chart_type values). **Read installed source read-only** before
  writing a Custom chart method or a Workspace JSON:
  `grep -n 'class Dashboard Chart' -A 40 apps/frappe/frappe/desk/doctype/dashboard_chart/dashboard_chart.py`.
  See skill `frappe-version-gotchas`.
- A Number Card "Custom" method must be whitelisted
  (`@frappe.whitelist()`), return `{"value": ..., "fieldtype": ...}`, and be
  read-only. Guard against `frappe.session.user == "Guest"`.
- Permissions are by **role** on the Workspace/Dashboard; never expose a KPI that
  leaks another role's data. Check a non-System-Manager role sees the right tiles.

## Safety tie-in (AGENTS.md)
Never edit files under `apps/frappe/` or `apps/erpnext/`. A standard Workspace/
Dashboard gets a **new custom** one (prefixed), not a core edit. Everything is
fixture/app-file versioned, idempotent, with a rollback note
(skill `erpnext-safe-change`). Prefer an existing standard chart/card if ERPNext
already ships it.

## Testing template
- Recreate the site data; open the Workspace as the target role.
- Cross-check every Number Card/Chart number against the equivalent list view or
  report — a wrong aggregate is worse than no chart.
- Confirm empty-data state renders (no divide-by-zero / blank page).
