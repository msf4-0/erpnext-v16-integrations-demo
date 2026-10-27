---
name: erpnext-workflows-permissions
description: Designs ERPNext Workflows (states, transitions, approval actions) and role/user permissions, permission levels, and sharing. Use on requests for approvals, sign-off, document status flows, role access, or "who can do what".
---

# erpnext-workflows-permissions skill — approvals + who-can-do-what

## What this skill is for (plain English)
Two related jobs:
1. **Workflow** — turn a document's status into a guided approval path
   ("Draft → Pending Supervisor → Approved/Rejected"), with each step restricted
   to a role.
2. **Permissions** — decide which roles may Read/Write/Create/Submit/Cancel a
   document, and whether a user sees only their own company/warehouse records.

## When to use it
- "This needs approval before it can continue."
- "Only storekeepers should be able to submit this."
- "Users should only see records for their own workstation/company."

## Workflow — how it maps
- **Workflow** doc: `workflow_state_field` (often `workflow_state`),
  `is_active`, `send_email_alert`.
- **Workflow State** rows: each has a name + `doc_status`
  (`0` Draft / `1` Submitted / `2` Cancelled) — the doc_status must match the
  underlying DocType's submittable rules.
- **Workflow Transition** rows: `state` → `action` → `next_state`,
  `allowed` (the role), `condition` (Python expression), `allow_self_approval`,
  `update_field`/`update_value` if it drives another field.
- **Workflow Action** master: the button labels (Approve/Reject/Send Back) —
  create these before transitions reference them.
- Do **not** hardcode a custom "status" Select field when the document needs real
  approval states — use Workflow (upgrade-safe + fixture-exportable).

## Permissions — layers, in order of preference
1. **Role Permission Manager** (Role → DocType grid): standard Read/Write/…
   For standard DocTypes, changes should land as **Custom DocPerm** fixtures,
   never by editing core `permlevel` files.
2. **Permission levels** (`permlevel` 1/2/…): hide sensitive fields (e.g. cost)
   on the *same* document from roles that shouldn't see them.
3. **User Permission**: row-level restriction by Company / Warehouse / Cost
   Center — use for "only their own site/warehouse". Combine with role
   permissions correctly or users get locked out.
4. **Share / if_owner**: ad-hoc sharing or "own records only".
5. **Role Profile**: bundle roles for onboarding, not a permission mechanism.

## Safety rules (AGENTS.md)
- Never widen access to sensitive doctypes (Payment Entry, GL Entry, Stock Ledger
  Entry, User, Role) without explicit confirmation.
- Never rename/delete standard fields or doctypes. Prefer a new custom field or
  a Custom DocPerm over an override.
- Fixture-export workflows and custom permissions, filtered by the agreed `cx_`
  prefix; every change idempotent with a rollback note (skill `erpnext-safe-change`).
- A workflow with a state whose `doc_status` conflicts with the DocType
  (e.g. a submit state on a non-submittable DocType) silently breaks saving.

## Testing template
- Create a user per role (supervisor, operator, storekeeper).
- Walk the full path: Draft → transition as allowed role → verify the next state
  and that the **button is hidden** for a disallowed role (API too, not just UI).
- Verify row-level `User Permission` filtering on a list view, not only the form.
- Cancel/reject path must complete without leaving an orphan state.
