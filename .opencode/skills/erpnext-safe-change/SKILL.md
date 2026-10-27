---
name: erpnext-safe-change
description: Backup -> dev/staging -> migrate -> test -> approve -> deploy runbook plus rollback tiers for ERPNext/Frappe changes. Use before applying any change to a site, when writing a rollback plan, OR when the user asks to roll back / undo / revert changes, remove a custom app, or return a site to base ERPNext.
---

# erpnext-safe-change skill — backup → dev → migrate → test → approve → deploy + rollback

## What this skill is for (plain English)
This is the "how do we not break the factory's live ERPNext" skill. Every change
(a new field, a validation, a report, a dashboard, a workflow) is applied on a
throwaway copy first, proven with a test, shown to the user, and only then put on
the real site — with a written undo plan ready before anything is deployed.
It fires automatically whenever a change is about to be applied to any **real**
site (not the sandbox), and whenever a rollback note is being written.

## When NOT to use it
- Read-only work (grepping core, reading `bench version`, building an Impact Matrix).
- Sandbox-only experiments (use skill `erpnext-test-sandbox` instead).

## Rollback triggers — load this skill the moment any of these appear
The user says (or implies) any of: **"roll back", "rollback", "undo my changes",
"revert", "remove the custom app", "get rid of the customisations", "back to base
ERPNext", "reset the site", "clean install"**. Also trigger when you are about to
uninstall an app or delete custom fields/doctypes. Pick the tier from the table
below — do **not** stop at removing a single app name from memory.

| User intent | Tier | Where |
|---|---|---|
| Undo one field / script / workflow / validation | Tier 1 | §Rollback tiers |
| Remove one custom app + its doctypes | Tier 2 | §Rollback tiers + §Full rollback |
| Site must match a clean ERPNext install (all apps + customisations gone) | **Tier 4** | §Tier 4 — full rollback to base ERPNext |

**Golden rule for rollback:** back up first (`bench --site <site> backup
--with-files`), record the filename, and verify afterwards (`list-apps`,
`git -C apps/erpnext status --short`, version tag). A rollback that only removes
the app directory but leaves `cx_` custom fields on standard doctypes is **not**
a rollback — uninstalling an app does **not** remove those.

## The golden rule
**No change reaches production without: a backup, a dev/staging run, a passing
test, a diff shown to the user, explicit "approved", and a rollback note.**
If any of those is missing, stop and ask.

## Pre-flight checklist (run before touching anything)
1. `bench version` — know whether this is v14 / v15 / v16. Never assume.
2. Confirm the **custom app name** and the **field/doctype prefix** (default `cx_`).
3. `bench --site <site> backup --with-files` — **record the exact filename**; it is
   the undo button. Do this on dev *and* again on production right before deploy.
4. Work only on a **dev/staging site**. Never develop directly on production.

## Deploy sequence (in order — do not skip)
1. Backup (`--with-files`) on the target site; record filename.
2. Apply the change on dev/staging.
3. `bench --site <dev> migrate` — this is what pushes new DocTypes / fixtures /
   patches into the database.
4. `bench --site <dev> run-tests --app <custom_app>` — at least one real test.
5. Show the user `git diff` + the Impact Matrix + a one-line summary.
6. Wait for explicit **"approved"**. Do not proceed on a vague "looks fine".
7. Production: backup again → point the app code at prod → `migrate` → smoke test.

## Smoke test (a change is not "done" until this passes)
Create and submit a real document through the affected flow (e.g. a Work Order →
its Job Cards, a Stock Entry), then check: ledgers/Stock Ledger Entry look right,
no new rows in **Error Log**, and the affected list/report/dashboard loads.
Cancelling must also work, not just creating.

## Rollback tiers (choose the smallest that works)
- **Tier 1 — disable (safest, instant):** turn off the thing without deleting it.
  Disable a Client/Script, Workflow, Notification, or a feature flag in
  Manufacturing Settings / Customize Form. Data stays intact.
- **Tier 2 — remove:** `bench remove-custom-field`, or delete the fixture entry and
  `migrate`, or `bench uninstall-app <app>`. **Trap:** custom fields created on
  *standard* DocTypes are not removed by uninstall — they need a reverse patch or
  `remove-custom-field`. Always write that step into the rollback note.
- **Tier 3 — restore backup:** `bench --site <site> restore <file> --with-files`.
  Last resort: it loses everything created since the backup.
- **Tier 4 — full rollback to base ERPNext:** return the site to a clean
  stock-Edition state — every non-core custom app removed and every custom field
  / property setter / custom doctype dropped, leaving only `frappe` + `erpnext`.
  See the section below. Use when the user wants "base vN", a clean install, or
  all customisations gone.

## Tier 4 — full rollback to base ERPNext (any version)

Goal: `bench --site <site> list-apps` shows **only `frappe` and `erpnext`**, no
`cx_`/custom fields remain on standard doctypes, and `apps/erpnext` + `apps/frappe`
are git-clean.

Run in order. Every step is idempotent (safe to re-run) and reversible via the
step-0 backup.

0. **Back up first and record the filename** — this is the undo button:
   `bench --site <site> backup --with-files`.
1. **List non-core apps** to remove:
   `bench --site <site> list-apps` → keep every line except `frappe` and `erpnext`.
2. **For each non-core app `<app>`** (skip `frappe`/`erpnext` — never touch those):
   a. `bench --site <site> uninstall-app <app> --yes` (drops its doctypes/tables).
   b. Remove the code + registration:
      `rm -rf apps/<app>`; delete its line from `sites/apps.txt`;
      `rm -f env/lib/python*/site-packages/<app>.pth`.
3. **Drop leftover customisations on standard doctypes** — uninstall does **not**
   remove Custom Fields / Property Setters / Client Scripts on core doctypes:
   - List them:
     `bench --site <site> execute "frappe.get_all" --kwargs "{'doctype':'Custom Field','filters':{'fieldname':['like','cx_%']},'fields':['name','dt','fieldname'],'limit_page_length':0}"`
   - Remove each (or the ones the user confirms):
     `bench --site <site> execute "frappe.db.delete" --kwargs "{'doctype':'Custom Field','filters':{'fieldname':['like','cx_%']}}"`,
     and the same for `Property Setter`, `Client Script`, `Server Script`,
     `Custom DocPerm`, `Workflow` — driven by the site's actual customisation list.
   - **Never** delete standard fields/doctypes or ecords that standard ERPNext owns.
4. `bench --site <site> migrate` — sync the DB schema back to stock.
5. **Verify (do not accept "no error" as success):**
   - `bench --site <site> list-apps` → exactly `frappe` + `erpnext`.
   - Custom-field check from step 3 returns `[]`.
   - `git -C apps/erpnext status --short` and `git -C apps/frappe status --short`
     are **empty** (core untouched).
   - `bench version` inside the container matches the intended tag (e.g. v16).
   - No `apps/<app>` directory remains.

> **Apps that are legitimately kept.** If the workspace ships an intentional app
> (e.g. `chat_widget` here), exclude it by name in step 2 — the goal is "base
> **plus the agreed apps**", not "delete everything". Confirm the keep-list with
> the user before deleting any app.

Helper: `sandbox/scripts/cx_rollback.sh` implements exactly this (backup →
uninstall → remove → drop leftovers → migrate → verify). Run it with the app name
argument, or `--all` to remove every non-core app. See `erpnext-test-sandbox`.

## Data-loss warnings (say these out loud in the rollback note)
- Submitted **GL / Stock** entries are real accounting events: you **cancel +
  amend**, you never delete. Restoring an old backup silently un-does them.
- Emails / SMS / WhatsApp already sent **cannot be un-sent**.
- Renaming or deleting a standard field/doctype is forbidden (AGENTS.md rule 4).

## Rollback note template (paste into every Implementation Plan)
```
Change: <one line>
Rollback: <Tier 1|2|3|4> — <exact command(s)>
Data loss risk: <none | describe>
Verified by: <test name>
```

- Tier 1 = disable · Tier 2 = remove the one app/field · Tier 3 = restore backup ·
  Tier 4 = full return to base ERPNext (all non-core apps + customisations gone).
- For Tier 4 name the exact keep-list (e.g. "base v16 + chat_widget") and the
  backup filename recorded in step 0.
