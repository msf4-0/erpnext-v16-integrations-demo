# Lowdefy Smart Inventory & Exception Management

Lowdefy operational front-end for the `comp_demo` ERPNext v16 stack (site `frontend`).
ERPNext stays the source of truth; Lowdefy is the operational UI; a small Node service
(no external deps) runs exception detection and stores only exception metadata.

See [`PLAN.md`](PLAN.md) for architecture, API endpoints, stages and limitations.

## Prerequisites

- ERPNext stack up at `http://localhost:8000` (run `F:\ERPNEXT\erpnextcomp_demo\setup.ps1`).
- An ERPNext API token for `Administrator` (or a role with read + Stock Entry rights).
- Node.js >= 22 (this host has v24) and Lowdefy installed (not yet — see note).

## Setup

```powershell
cd F:\ERPNEXT\erpnextcomp_demo\lowdefy
Copy-Item .env.example .env     # then fill ERPNEXT_API_KEY / _SECRET
```

Start the exception service:

```powershell
cd server
$env:ERPNEXT_URL='http://localhost:8000'
$env:ERPNEXT_API_KEY='<key>'; $env:ERPNEXT_API_SECRET='<secret>'
node index.js
```

Start Lowdefy (dev), pointing it at the `lowdefy` folder; the app resolves `_secret`
values from the environment above.

## Current state

- Scaffold + detection logic written, **not yet run against live data**.
- Blocked on: Docker Desktop not running (ERPNext down) and Lowdefy not installed.
- Bring the stack up first, mint a token, then test each workflow end-to-end.
