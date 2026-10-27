# Shopify → ERPNext via Node-RED — setup

Automates the parts of the integration that are mechanical, and tells you exactly
which parts are not automatable.

```
shopify-setup\
  setup-shopify-erpnext.ps1   the script (Windows PowerShell 5.1+ / PowerShell 7)
  .env.example                copy to .env and fill the blanks
  .env                        your local config - never commit
  setup-shopify-erpnext.log   append-only run log (secrets masked)
```

Requires **PowerShell 5.1 or newer** and treats this build's ERPNext v16 as the
baseline (the original brief was written for v12; see findings 5-6 for what
changed on v16).

## Run order

```powershell
# 1. one-time: create your config
Copy-Item .env.example .env
notepad .env            # fill SHOPIFY_CLIENT_ID/SECRET, ERP_ADMIN_PASSWORD, WEBHOOK_SECRET

# 2. dry run - shows every action it would take, writes nothing
pwsh -File .\setup-shopify-erpnext.ps1 -WhatIf

# 3. real run
pwsh -File .\setup-shopify-erpnext.ps1

# 4. after a client-secret rotation, force new credentials + redeploy
pwsh -File .\setup-shopify-erpnext.ps1 -ForceToken
```

Day-to-day, the script is safe to re-run at any time; unchanged steps report
`[SKIP]`. Schedule it if your tokens are short-lived:

```powershell
schtasks /create /tn "shopify-erpnext setup" /sc daily /st 07:00 ^
  /tr "pwsh -NoProfile -File F:\ERPNEXT\erpnextcomp_demo\shopify-setup\setup-shopify-erpnext.ps1"
```

## What each run does

| Step | Action | Idempotency rule |
|---|---|---|
| 0 | Preflight: node/npm/docker/ngrok, Docker daemon, `ERP_URL` ping, required env keys | fails fast, changes nothing |
| 1 | Node-RED on :1880, installs globally only if missing | `[SKIP]` when the port already answers |
| 2 | ngrok tunnel, `ngrok config add-authtoken` | `[SKIP]` when a tunnel with the right host is already up |
| 3 | Shopify Admin API token (client_credentials) | always minted (they are 24 h) |
| 4 | ERPNext API key for the admin user | reuses `ERP_API_TOKEN` **if it authenticates**; only generates when it does not |
| 5 | `Shopify Access` record | found by `shop_domain_url`, updated in place |
| 6 | `Shopify Settings` single doctype | populated when it exists, `[SKIP]` with an explanation when it does not |
| 7 | Node-RED flow: credentials + URLs, then deploy | backs up the JSON first; `[SKIP]` deploy with `-SkipFlowDeploy` |
| 8 | 3 ERPNext webhooks (URL, JSON body, enabled) | written from inside the bench; `[SKIP]` when URL + enabled + JSON body already match |
| 9 | Smoke tests: ERP auth, Shopify auth, 3 public endpoints | summary table, exit 1 on failure |

## Fieldnames: verified, not guessed

The `Shopify Access` mapping was read from the live DocType meta on this build
(`GET /api/resource/DocField?filters=[["parent","=","Shopify Access"]]`):

| Concept | Actual fieldname |
|---|---|
| Company Name | `link_name` |
| Shopify Account Type | `shopify_account` (Select: Main / Secondary / Third) |
| App Type | `app_type` |
| Domain URL | `shop_domain_url` |
| API Key | `api_key` |
| Secret Key | `secret_key` |
| Access Token | `access_token` |
| Shopify API Version | `updated_version` |
| Company | `company` (Link → Company) |
| Bank Account | `bank_account` (Link → Account) |
| Shopify API URL | `shopify_url` — **this is the autoname field** (`autoname: field:shopify_url`), so it must be set or creation fails |

The script re-reads this meta on every run and skips (with a warning) any field
that is not present, so a different app version degrades loudly instead of
writing garbage.

## Findings from running it against this build

### 1. There is no `Shopify Settings` doctype in this build.
The installed app is `shopify-shrdc`, which ships exactly two doctypes —
`Shopify Access` and `Shopify Link`. There is no `enable_shopify` /
`cost_center` / `warehouse` / `price_list` / tax-row settings singleton; that
belongs to a different Shopify app. Step 6 therefore detects the doctype and
reports `[SKIP] DocType not installed in this app` rather than pretending. If you
later install the app that has it, step 6 starts working with no code change,
because it resolves every fieldname from the live meta.

**2. `Node-RED` must not use `localhost` to reach ERPNext.**In this build Node-RED runs in the compose network (`comp_demo-node-red-1`), so
`http://localhost:8000` inside the flow means Node-RED itself. Every ERPNext node
URL is therefore rewritten to `ERP_INTERNAL_URL` (`http://bench:8000`). Set
`ERP_INTERNAL_URL=$ERP_URL` if you run Node-RED directly on the host.

**3. The group defaults in the spec do not exist in this site.**
Verified live: company `SHRDC`, cost centre `Main - SHRDC`, warehouse
`Stores - SHRDC`, price list `Standard Selling`, customer group
`All Customer Groups`, tax account `GST - SHRDC`.
`Selangor Human Resource Development Centre`, `Cimb Bank - SHRDC` and
`SHRDC Bank - SHRDC` (the spec's values) are **not** valid here — `Cimb Bank -
SHRDC` does not exist at all. The real bank/cash accounts are
`Bank Accounts - SHRDC`, `SHRDC Bank - SHRDC`, `Cash - SHRDC`, `Cash In Hand - SHRDC`.
`.env.example` therefore ships the values that actually exist, and the script
validates every Link against the site before writing (and prints the valid
options when one is wrong).

**4. Node-RED cannot deploy to a bind-mounted `flows.json` (Docker Desktop).**
`POST /flows` returns `400`, and the body from Node-RED is
`EBUSY: resource busy or locked, rename '/data/flows.json.$$$' -> '/data/flows.json'`.
Node-RED persists a deploy by writing a temp file and renaming it over
`/data/flows.json`; when that file is a single-file bind mount from a Windows
host, Docker Desktop fails the rename. **The editor's Deploy button fails the
same way.** The script detects the bind mount and uses the equivalent path:
write the patched JSON on the host (it *is* the bind source) and restart the
container. On a volume-mounted or standalone Node-RED it still uses the Admin
API.

**5. A JSON webhook body needs `webhook_json`, not `webhook_data`.**
In ERPNext v16 `webhook.py` does, for `request_structure = "JSON"`:
`validate_template(self.webhook_json); self.webhook_data = []`. Writing the
`Webhook Data` child rows therefore produces an **empty body with no error**.
The three bodies are set as Jinja templates (`{"delivery_note": "{{ doc.name }}"}`
etc.). This is what the spec's "body:" lines have to become on v16.

**6. `X-Webhook-Secret` is not stored on this build — reported, not faked.**
`Webhook Header` child rows persist with an **empty `parent` and empty `key`/`value`**
via both `/api/resource` and the server-side document API, so the header never
attaches. The script writes it, then reads the webhook back and reports
`WARN  X-Webhook-Secret not persisted on 3/3` instead of claiming success. Inbound
routing is unaffected (the flow does not require the header); the URL, method,
JSON body and `enabled` flag all verify as correct. Fixing it needs a look at the
`Webhook Header` child table server-side.

**7. `Shopify Access` cannot be updated by name.**
Its `autoname` is `field:shopify_url`, so the docname is
`https://4e1075.myshopify.com/admin/api/2026-04/` — it contains slashes, and
`PUT /api/resource/Shopify Access/<that>` returns 404 because the path splits.
The script uses `frappe.client.set_value` with the name in the body instead.

**8. PowerShell 7 is not installed on this machine.**
The request asked for a PowerShell 7 script; `pwsh` is absent here, so an
`#Requires -Version 7.0` script would not run at all. The script is therefore
written to run on **Windows PowerShell 5.1 and PowerShell 7** — it avoids the
three 7-only constructs (`-SkipHttpErrorCheck`, `-StatusCodeVariable`,
`ConvertFrom-Json -Depth`) and was tested end-to-end on 5.1. Raise the
`#Requires` line if you only ever run it on 7.

Two 5.1 traps that cost real time and are commented in the code:
`ConvertFrom-Json -InputObject` returns a JSON **array as one nested object**
(read through the pipeline instead), and `@(@(..),@(..))` written one element
per line **flattens** the nested arrays (which silently produced a 1-D Frappe
filter that matched nothing).

## Manual steps the script cannot do

1. **Install Docker Desktop + ERPNext.** The script assumes an ERPNext v16 site is
   already reachable at `ERP_URL`. For this build that is the `comp_demo` stack
   (`F:\ERPNEXT\erpnextcomp_demo`) — bring it up with `setup.cmd` there, or run
   the full `up.ps1`. The upstream reference is the `msf4-0/ERPNext-ECommerce-Shopify`
   repo; cloning and installing that is outside this script.
2. **Create the Shopify Dev Dashboard app.** Shopify admin → Settings → Apps →
   Develop apps → create app → configure Admin API scopes → copy the **client id**
   and **client secret** into `.env`. The script cannot create the app or grant
   scopes.
3. **Reserve the ngrok static domain.** The free plan allows one; reserve it in
   the ngrok dashboard and put it in `NGROK_DOMAIN`. Without a reserved domain the
   public URL changes on every restart and the webhook URLs go stale.
4. **Install the ERPNext apps** (`shopify`, and `barcode_shrdc` for the stock
   endpoints). `bench --site <site> list-apps` must show `shopify`.
5. **Grant the integration user roles.** The ERPNext user whose key is generated
   needs at least Sales / Stock / Manufacturing permissions for the flow's
   document reads. Out of scope for the script.
6. **Shopify webhook registration** (optional, inbound direction). This script
   configures ERPNext → Node-RED. Pointing Shopify's own webhooks at
   `https://<domain>/shopify-order` is a Shopify-admin action.
7. **Accept that the ERPNext site DB is tmpfs.** In this build a container stop
   wipes the site, which also wipes `Shopify Access` and the three webhooks —
   re-running this script after `setup.cmd` restores them.

## Caveats handled in code

- **ngrok domain drift** — webhook URLs are rebuilt from `NGROK_DOMAIN` (or the
  live tunnel URL) on every run; a changed host produces `[FIXED]` on all three
  webhooks.
- **token expiry** — `expires_in` is reported, a sub-24 h lifetime prints the
  scheduling hint, and `-ForceToken` cleanly redoes steps 5–7.
- **version drift** — every doctype fieldname comes from live meta; anything
  absent is listed under "fields not present, skipped".
- **secrets** — read from `.env`, never echoed; masked in console *and* in the
  log via both an exact-value list and pattern rules (`shpat_…`, `shpss_…`,
  `token <k>:<s>`, ngrok authtoken shape).
- **flow safety** — the flow JSON is backed up before patching, and the deploy
  failure path prints the exact restore command.

## Exit codes

`0` all checks passed · `1` preflight or a write failed (see the FAIL rows).
