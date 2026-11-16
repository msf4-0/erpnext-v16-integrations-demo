# Security policy

## What this repository is

A **demo** stack: ERPNext v16, MariaDB, Redis, Node-RED, Metabase and a planner
service, all on a developer machine. It is not hardened for production and must
not be exposed to the public internet as-is.

## Reporting a vulnerability

Open a private security advisory through GitHub:
**Security → Advisories → Report a vulnerability**
(<https://github.com/msf4-0/erpnext-v16-integrations-demo/security/advisories/new>).

Please do not open a public issue for a vulnerability. Include the affected
component, a reproduction, and whether credentials or data are exposed.

## Known design decisions (not vulnerabilities)

- The demo ships default logins (`Administrator`/`admin`,
  `demo@compdemo.local`/`demo`) and a default MariaDB root password in
  `.env.example`. Intended for a local demo only.
- `setup.ps1` mints an ERPNext API key/secret and writes it to `.env`, which is
  git-ignored.
- ngrok exposes the local bench publicly while it runs. Stop the tunnel when you
  are done; the URL changes on each start unless `NGROK_PUBLIC_URL` is pinned.
- The published bench image contains no secrets. `.env` is not baked in.

## If you fork this for real use

1. Change every default password and rotate the ERPNext API key/secret.
2. Bind services to `127.0.0.1` or put them behind an authenticating proxy.
3. Use a managed database with backups; the demo's MariaDB volume is not a
   backup strategy.
4. Keep `SHOPIFY_*`, `NGROK_AUTHTOKEN` and Metabase admin credentials out of
   the image and out of git.

## Scope

In scope: the scripts in this repository, the Dockerfiles, the published GHCR
image, and the custom apps under `repos/`. Out of scope: vulnerabilities in
ERPNext/Frappe, MariaDB, Redis, Node-RED, Metabase or ngrok themselves — report
those upstream.
