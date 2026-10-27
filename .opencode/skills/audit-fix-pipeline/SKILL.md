---
name: audit-fix-pipeline
description: Shared pipeline contract for the code-auditor and code-fixer agents. Use when creating/updating findings, assigning finding IDs, changing finding status, or handing work between audit and fix. Defines the findings.json schema, the status lifecycle, and who may write what.
---

# audit → fix → verify pipeline

One shared index: **`.audit/findings.json`**. The auditor creates findings and verifies; the fixer fixes and never self-certifies. Markdown reports in `.audit/reports/` are human-readable; `findings.json` is the source of truth for status.

## Finding IDs
Prefix by type; number sequentially across all reports; **never reuse an ID**:

| Prefix | Type |
| --- | --- |
| `BUG-` | functional / data correctness |
| `SEC-` | security |
| `PERM-` | permissions / roles / tenant isolation |
| `UI-` | UI / UX |
| `PERF-` | performance / scalability |
| `A11Y-` | accessibility |

Examples: `BUG-001`, `SEC-002`, `PERM-003`, `UI-004`.

## Status lifecycle
```
Open → In progress → Fixed (pending verification) → Verified → Reopened
                       (terminal-ish: Won't fix, Cannot reproduce, Needs decision)
```
Allowed writers:
- **code-auditor**: `Open`, `Verified`, `Reopened`, `Won't fix`, `Cannot reproduce`.
- **code-fixer**: `In progress`, `Fixed (pending verification)`, `Needs decision`, `Cannot reproduce` + `fix_commit`.

Neither agent edits the other's evidence (repro scripts, screenshots) except to **add** new files.

## findings.json schema
```json
{
  "schema_version": 1,
  "statuses": ["Open", "In progress", "Fixed (pending verification)", "Verified",
               "Reopened", "Won't fix", "Cannot reproduce", "Needs decision"],
  "findings": [
    {
      "id": "BUG-001",
      "title": "Short human title",
      "severity": "Critical | High | Medium | Low",
      "type": "functional | data | security | permission | ui | performance | accessibility",
      "status": "Open",
      "confidence": "Confirmed | Suspected | Needs verification",
      "project": "repo-or-app name",
      "file": "path/to/file.py",
      "line": 123,
      "report": ".audit/reports/<date>-<scope>.md",
      "repro": ".audit/repro/<script>.py",
      "fix_commit": null,
      "attempts": 0,
      "evidence": "one-line evidence / command / link",
      "notes": "",
      "last_updated": "YYYY-MM-DD"
    }
  ]
}
```

Rules:
- Append new findings; never renumber or reuse an ID.
- Update `last_updated` on every status change.
- Increment `attempts` on each fix attempt; at 2, move to `Needs decision`.
- `fix_commit` is set only by code-fixer when status becomes `Fixed (pending verification)`.

## Handoff
- Auditor → fixer **only when the user explicitly asks** (or `/pipeline-fix`). The auditor never starts fixes.
- Fixer → auditor **only to re-verify a specific ID** after fixing (read-only verification). `/verify-fix <ID>`.
- The verifier re-runs the original repro + browser flow, reviews the `fix_commit` diff, checks a covering test exists, then sets `Verified`/`Reopened`.

## Hard limits
- Max 2 fix→verify attempts per finding, then `Needs decision`.
- Never push/merge/touch `main`; the user reviews the fix branch.
- If the working tree is dirty or tests already fail, record the baseline and stop for the user's decision.
