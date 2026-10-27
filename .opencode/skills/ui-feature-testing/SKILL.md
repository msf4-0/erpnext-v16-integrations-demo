---
name: ui-feature-testing
description: Browser-based UI feature testing workflow for the code-auditor agent using Playwright MCP and Chrome DevTools MCP. Use when asked to test a feature/flow in a real browser, test the whole app, run a smoke test, verify role permissions in the UI, or capture screenshots and console/network evidence.
---

# UI feature testing

Drive the app like a real user in a real browser. Playwright MCP for interaction/screenshots; Chrome DevTools MCP for console, network and performance. **Only** against `localhost`, `127.0.0.1`, `0.0.0.0`, or a staging URL the user explicitly gives you.

## 0. Preconditions
- Confirm the target URL is local/staging. If it looks like production, **stop and ask**.
- Get test credentials per role from the user (admin, regular, read-only, unauthenticated). Never guess.
- Confirm browsers are installed. If Playwright errors with "Executable doesn't exist", tell the user to run `npx playwright install chromium` — that is a manual, one-time step.

## 1. DISCOVER
Read routes, page components, forms, and API calls. Build a feature inventory:
- Pages/views and their routes.
- Forms and their fields + validation.
- Buttons/actions (submit, delete, export, bulk actions).
- Modals/dialogs and their flows.
- Roles and what each is supposed to see/do.
- Key end-to-end flows (login, primary create/update, checkout/publish, etc.).

**Present the inventory plus a test plan before executing** (required for `/ui-test-all`).

## 2. START
- Detect the start command (`package.json` scripts like `dev`/`start`/`serve`, `Makefile`, `docker-compose`).
- Start it in the background; poll until healthy: `curl http://localhost:<port>` until 200/timeout.
- On failure, report the exact error and the most likely cause. Do not retry endlessly.

## 3. EXECUTE (per flow)
**Happy path first**, then negative paths:
- Empty required fields; invalid formats; too-long input; special characters / unicode.
- Double-click submit; rapid repeated actions.
- Back/forward navigation; refresh mid-flow; deep-link directly to a mid-flow URL.
- Expired session / logged-out state.

For each step verify **both** the visible result and the underlying behavior:
- Console errors (Chrome DevTools) — any error or warning.
- Network: failed (4xx/5xx) or slow requests, wrong payloads, duplicated requests.
- **Persistence**: reload the page or re-query the API and confirm the change stuck.

**Every role**:
- Log in as each role; confirm the UI shows only permitted actions.
- Attempt **direct URL access** to restricted pages.
- Attempt **direct API calls** (e.g. via `curl` to localhost or DevTools fetch) to restricted resources.
- UI-hidden ≠ server-enforced — record when the server allows what the UI hides.

**Responsive & states**:
- Viewports: mobile (~375px), tablet (~768px), desktop (~1440px).
- Loading, empty, and error states.
- Accessibility: labels/associated inputs, keyboard navigation, focus order, visible focus, contrast, ARIA roles, alt text, form error announcements.

**Performance**:
- Slow page loads; layout shift (CLS); large bundles; excessive/duplicate requests; blocking resources.

## 4. CAPTURE
For every failure capture:
- Screenshot to `.audit/screenshots/<date>-<scope>-<n>.png` (redact secrets/PII).
- Numbered steps to reproduce.
- Console output excerpt.
- Relevant request/response (redacted) — URL, method, status, payload.
- Trace back into source and cite `file:line`.

## 5. VERIFY FIXES
When the user reports a fix, re-run the **exact same repro** (same role, viewport, steps) and report Pass/Fail against the original expected behavior. Do not vary the steps.

## 6. Reporting
- Fill the **Feature verification matrix** (Feature/Flow | Role | Result | Evidence | Notes) in `.audit/reports/<date>-<scope>.md`.
- Emit bug blocks for failures using the standard schema.
- List what was **not tested** (roles without credentials, flows skipped) explicitly.

## 7. Cleanup
- Close browser contexts/tabs you opened.
- Stop background dev servers you started.
- Remove test data you created where feasible; never bulk-delete.

## Tool naming
MCP tools are prefixed by server name (`playwright_*`, `chrome-devtools_*`). Use the navigation/click/type/screenshot tools from Playwright and the console/network/performance tools from Chrome DevTools. If a browser tool is unavailable for this agent, report it rather than falling back to unsafe methods.
