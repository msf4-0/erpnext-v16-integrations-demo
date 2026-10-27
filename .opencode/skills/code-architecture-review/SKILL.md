---
name: code-architecture-review
description: Architecture wellness review for the code-auditor agent. Use when asked to assess code quality, structure, coupling, module boundaries, testability, consistency, dead code, or overall maintainability of a repo/module, and to produce a prioritized architecture report.
---

# Code-architecture review

Assess whether the codebase is structurally healthy and maintainable — independent of any single bug. Read-only. Output a prioritized, evidence-backed report.

## 1. Map the architecture
- Directory/module layout, entrypoints, layering (UI / domain / data).
- Dependency direction: does the domain depend on infrastructure, or vice versa?
- Key abstractions and their responsibilities.
- Build/config, runtime targets, and external dependencies.

## 2. Smells to look for
- **Coupling**: god objects/functions; modules reaching across boundaries; framework leakage into domain; circular dependencies; globals/singletons as hidden coupling.
- **Cohesion**: a module doing too many unrelated things; shotgun surgery (one change touches many files).
- **Duplication**: copy-paste logic; near-duplicate handlers; parallel implementations of the same rule.
- **Abstraction balance**: premature abstraction vs missing seams; leaky interfaces; unnecessary indirection.
- **Error strategy**: inconsistent (exceptions in one place, result codes in another, silent failures elsewhere); no central boundary for errors.
- **State**: scattered mutable global state; implicit lifecycle; hidden side effects.
- **Testability**: hard-to-inject dependencies, static/global access, no seams for fakes; tests coupled to implementation details.
- **Consistency**: naming, formatting, patterns, and conventions applied unevenly; mixed paradigms; config conventions.
- **Dead / speculative code**: unused modules, feature flags never removed, commented-out blocks, abandoned `TODO`s.
- **Dependency health**: outdated/vulnerable packages (use the audit commands), unpinned versions, heavy deps for small needs.
- **Operability**: logging quality, observability, config management, secrets handling, migrations discipline.

## 3. Evidence, not vibes
For every finding cite `file:line` and, where useful, a short snippet. Prefer quantified impact ("this rule is reimplemented in 4 files") over adjectives.

## 4. Prioritization
Rank by **impact × likelihood**:
- **Critical**: blocks correctness/security or makes change dangerous.
- **High**: will cause recurring bugs or severe maintenance drag.
- **Medium**: local pain, worth a planned cleanup.
- **Low**: polish / nice-to-have.
Separate **quick wins** (small, safe) from **structural investments** (larger refactors with a suggested sequence).

## 5. Report format
Save to `.audit/reports/<date>-architecture-<scope>.md`:

```
# Architecture review — <scope> — <date>

## Summary
<3–6 lines: overall health, biggest risks, biggest wins>

## Scores (optional, 1–5)
Boundaries: /5 | Cohesion: /5 | Error handling: /5 | Testability: /5 | Consistency: /5 | Dependency health: /5

## Findings
### [Severity] <title>
- Where: <file:line>
- Why it matters: <impact>
- Evidence: <snippet / counts>
- Suggested direction: <approaches, tradeoffs; do not apply>

## Quick wins
- ...

## Structural investments (suggested order)
1. ...

## Not reviewed
- <areas not covered and why>
```

## 6. Rules
- Never edit source; propose only. Writes go to `.audit/` only.
- Group related smells; don't inflate the count.
- Respect the project's existing conventions — flag inconsistency, don't impose a style the project never had.
- Distinguish confirmed structural problems from stylistic preferences.
