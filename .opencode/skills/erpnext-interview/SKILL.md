---
name: erpnext-interview
description: Runs the question-first ERPNext/Frappe requirements interview (question-bank.md phases 0-10). Use when a new ERPNext customization, report, dashboard, or DocType request needs requirements gathered before a spec is written.
---

# erpnext-interview skill — runs the Interview Protocol using question-bank.md

## What this skill is for (plain English)
This is the "ask before you build" skill. Factory workflows have details a
developer cannot guess (who approves, which warehouse, what happens when stock
is short). We collect those in small, friendly batches so the spec is right the
first time, instead of discovering gaps after coding.

## How it runs
Ask one phase at a time (Phase 0 → 10), max 3–4 numbered questions per message, multiple-choice options plus "I'm not sure".
Formatting is MANDATORY: render each question as its own block — the number+question on its own line, then each option (`a) `, `b) `, `c) `, `d) `) on its own line, with a blank line between question blocks. NEVER write a running paragraph or inline the options on one line. Example:

```
1.2. How would you like to solve issue X?
a) Solution A
b) Solution B
c) Solution C
d) I'm not sure — explain the options first
```

If "not sure": explain each option in plain language with a one-line factory-floor example, then re-ask.
After each phase: 2–3 line summary + "Correct?" before proceeding.
Inspect first (read-only: `bench version`, list apps, grep custom fields/fixtures) then ask only what's missing.
After all phases: build Requirements Spec + Impact Matrix + Implementation Plan; STOP, wait for "approved".
Demo data is OFF BY DEFAULT: always include the one question "Do you want me to create demo data to test this change? (yes / no / minimal subset)" in the confirmation step (10.3), and only seed data on an explicit yes, scoped to the user's issue (skill `erpnext-demo-data`). No answer / "no" → skip demo data.
On mind-change: re-run only affected phases, update spec. Use question/ask tool if available, else plain chat.
9. Fast-track (test mode / pre-approval): if the user says this is a test, tells you to take the recommended answers, or otherwise waives the interview, DON'T skip the safety net — collapse the remaining phases using the recommended options, record each as `x.y … Correct.` in a "Collapsed interview" section of the spec, still produce Requirements Spec + Impact Matrix first, then implement on the SANDBOX. Production still needs a separate explicit "approved".
