---
name: secure-coding
description: Security fix patterns for the code-fixer agent. Use when fixing authentication, authorization, tenant isolation, injection, secrets, or password-handling findings. Emphasizes fixing the cause server-side and adding a test that proves the exploit no longer works.
---

# Secure coding / security fixes

Fix the **cause**, not the presentation. Hiding a control in the UI is not a fix. Every security fix ships with a test that proves the exploit no longer works.

## Authorization & tenant isolation
- Enforce authorization **server-side**, on every read AND write, not just the page/route.
- Scope **every** query and mutation by the tenant discriminator (`company_id` / `tenant_id`):
  ```sql
  -- wrong: WHERE id = %s
  UPDATE documents SET active = 0 WHERE id = %s AND company_id = %s
  ```
- Check the guard at the data layer (DAO), not only the UI.
- Add a test: user/tenant A attempts to access tenant B's row → denied.

## Injection
- Always parameterized queries (`%s` placeholders), never string concatenation/f-strings with user values.
- Beware `ORDER BY`/table names (can't be parameterized) — use an allow-list.
- Escape/validate before rendering user data into HTML (avoid `unsafe_allow_html` with user input).

## Authentication & sessions
- Passwords: use an adaptive hash (bcrypt/argon2) with per-user salt. Migrating an existing unsalted store must be **staged and backward-compatible** (e.g. verify old hash, then rehash on next successful login) — ask before implementing.
- Re-check role/`is_active`/tenant on each request (or short-lived session), so demotion/deactivation takes effect.
- Never log or echo secrets, tokens, or PII. Redact in evidence.

## Secrets & credentials
- Remove hardcoded secrets/credentials from code → environment variables.
- Remind the user that exposed secrets **must be rotated**, and that git history may still contain them. **Do not rewrite history.**

## Exposure
- Turn off debug/verbose error output in production configs.
- Don't return internal stack traces to users; log server-side, show a generic message.

## Verification
- Write the exploit/negative test first (it should fail on the old code), then fix, then confirm it passes and the positive path still works.
- Re-run the full suite; check the fix didn't open a new hole (e.g. over-broad allow).
