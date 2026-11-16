# my_invois — Malaysian LHDN MyInvois e-invoicing

A working, **gated** MyInvois layer for the comp_demo ERPNext v16 stack. It is
the app the README used to describe as "not in this repository"; it is in
`repos/my_invois` and is installed by the seed/`setup.ps1` flow.

## What is here

| Piece | Purpose |
|---|---|
| `my_invois/my_invois/api.py` | settings, UBL-ish document builder, validate, submit, refresh status, cancel |
| `my_invois/fixtures/custom_field.json` | TIN/BRN/SST + MyInvois status, UUID, long ID, submission UID, timestamps, rejection reason |
| `my_invois/fixtures/client_script.json` | Sales Invoice buttons: Validate, Submit, Get LHDN Response, Cancel |
| `my_invois/tests/test_gating.py` | proves the no-credentials path makes **no** outbound call |

## Configuration (site_config.json, not a DocType)

The API reads `frappe.conf`, so credentials never live in the database:

```json
{
  "myinvois_environment": "Sandbox",
  "myinvois_client_id": "...",
  "myinvois_client_secret": "...",
  "myinvois_api_base_url": "https://preprod-api.myinvois.hasil.gov.my",
  "myinvois_token_endpoint": "https://preprod-api.myinvois.hasil.gov.my/connect/token"
}
```

`get_myinvois_settings()` reports `configured: false` when the client id or
secret is missing, and `submit_to_myinvois()` then:

1. validates the invoice,
2. sets `myinvois_status = "Pending Validation"`,
3. returns a message that says explicitly it was **NOT** submitted,
4. makes no HTTP request at all.

That is the demo path. With credentials present it fetches a token, builds the
document, posts to `/api/v1.0/documentsubmissions`, and records the UUID,
submission UID and rejection reason.

## Install

The seed service installs it automatically (idempotent). By hand:

```bash
SP=$(dirname "$(find /home/frappe/frappe-bench/env -name frappe.pth -print -quit)")
printf '/home/frappe/frappe-bench/apps/my_invois\n' > "$SP/my_invois.pth"
bench --site frontend install-app my_invois
bench --site frontend migrate
bench --site frontend clear-cache
```

Compose already bind-mounts `./repos/my_invois` at
`/home/frappe/frappe-bench/apps/my_invois`, so host edits are live.

## Test

```bash
bench --site frontend run-tests --app my_invois
```

## Limits

- UBL shaping covers the fields this demo produces; it is not a certified
  MyInvois SDK and does not implement digital signatures / `documentHash`
  beyond what LHDN's JSON submission accepts in sandbox.
- No polling scheduler: status refresh is a manual button.
- Sandbox only has been exercised; production credentials are untested.
