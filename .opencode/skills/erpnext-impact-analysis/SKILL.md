---
name: erpnext-impact-analysis
description: Read-only grep of apps/erpnext to build an Impact Matrix before coding. Use when assessing which standard DocTypes, hooks, reports, dashboards, or notifications a change touches, and its risk/rollback.
---

# erpnext-impact-analysis skill — read-only grep of apps/erpnext → Impact Matrix

## What this skill is for (plain English)
Before writing any code, work out **what the change will touch**. That way a
"small" field add does not silently break a report, a workflow, or an
automation that depends on the DocType. This produces the Impact Matrix the user
approves before we start.

## When to use it
Every time a request could change a standard DocType or hook. Not needed for the
sandbox rebuild runbook (that's `erpnext-test-sandbox`).

## How (read-only only — never edit a match)
1. Find usage:
   `grep -rn "<DocType>" apps/erpnext --include=*.py --include=*.js --include=*.json`
2. Find hooks: search `hooks.py` for `doc_events`, `scheduler_events`,
   `override_doctype_class`, `override_whitelisted_methods`.
3. Find related/linked docs: `make_*`, `get_mapped_doc`, Link/Master fields.
4. Note anything that consumes the DocType: reports, dashboard charts, number
   cards, notifications, workflows, print formats, permissions.

## Classify each touched DocType
- **Type:** Standard / Custom.
- **Action:** read / add field / hook / new / modify behavior.
- **Mechanism:** Custom Field / Property Setter / Client Script / Server Script /
  `doc_events` / new DocType / report / print format / notification / workflow /
  dashboard / workspace / permission.
- **Risk:** low / medium / high (high = accounting, stock, submitted docs, or a
  core hook).
- **Rollback:** disable / remove / restore (see skill `erpnext-safe-change`).

## Rules
- Prefer standard ERPNext configuration if the feature already exists.
- Output the table per `templates/impact-matrix.md`.
- Confirm the matrix with the user (Phase 9) **before** writing any code.
