# Handoff — remaining work (next workspace)

> Authoritative stack architecture, ports, versions, and database durability:
> [`ARCHITECTURE.md`](ARCHITECTURE.md).

> Session ended at a clean checkpoint. This file is the authoritative "what's
> done, what's left, and the exact commands" for the next agent.

## 1. DONE and VERIFIED live (Item Tracker — Part 2)

All four fixes are in the running container (`comp_demo-bench-1`), rebuilt, and
served. No DB migration was needed (changes reuse existing doctypes/fields).

| Fix | File | Evidence |
|---|---|---|
| Stock Entry scan now sets `s_warehouse`/`t_warehouse` from header (fixes missing-warehouse submit error) | `repos/item_tracking/item_tracking/public/js/item_tracking_scan.js` | asset served 200 with new code |
| QR encodes **raw `tracking_id`**, not a `/tracked_item_lookup` URL | `repos/item_tracking/item_tracking/item_tracking/doctype/tracked_item/tracked_item.py` | container source verified |
| Inline camera scanner (`getUserMedia` + `BarcodeDetector` → `show_popup`) | same JS (`scan_camera`) | asset served 200 |
| Navigation: `config/desktop.py` module entry + Item-form "Tracked Units"/"Create Tracked Units" buttons | `config/desktop.py`, `public/js/item_tracker_item.js`, `hooks.py` (`doctype_js`) | assets served 200 |

Backend Stock Entry lifecycle (submit/cancel/history/duplicate/warehouse-mismatch)
was already correct and passed its own test — no change needed.

## 2. MyInvois (Part 1) — written; no build installer; fixtures never synced

The `repos/my_invois` source (package `my_invois`) is written, but no supported
build/startup entry point installs it. The installation evidence below is from
a prior live-site snapshot; current runtime status is unverified. Its fixtures
never synced, so this is not a working installed integration.

- `hooks.py` (`fixtures = ["Custom Field", "Client Script"]`)
- `fixtures/custom_field.json` — MyInvois status/classification/UUID/references
  on `Sales Invoice`; TIN/BRN/SST on `Customer`, `Company`, `Supplier`
- `fixtures/client_script.json` — Sales Invoice "Validate for MyInvois" /
  "Submit to MyInvois" buttons
- `my_invois/my_invois/api.py` — `validate_for_myinvois`,
  `prepare_myinvois_payload`, `submit_to_myinvois` (gated on credentials; never
  fakes submission), `get_myinvois_settings`, `_get_access_token`
- `config/desktop.py`, `modules.txt`, `setup.py`, `requirements.txt`

**Historical install evidence:** `bench --site frontend list-apps` and
`site_config.json -> installed_apps` and `sites/apps.txt` all list `my_invois 0.0.1`.
This does not show that the current build installs the app.

### Remaining issue: custom fields did NOT materialize

`GET /api/resource/Custom Field/Sales Invoice-myinvois_status` returns empty and
`Customer-myinvois_tin` returns 404 — the fixture sync did not create the Custom
Field / Client Script rows even though `bench migrate` reported success.

**Possible causes to check (in order, only after explicitly installing the app):**
1. Fixtures may need `bench --site frontend export-fixtures` OR a re-run of
   `bench --site frontend migrate` **after** the app was added to `apps.txt` +
   `install-app` (the migrate ran in a step where module map may not yet have
   included `my_invois`).
2. Custom Field fixture rows may require the `module` field (e.g.
   `"module": "My Invois"`) — item_tracking's fixture omitted it, but confirm.
3. In Frappe v16 the `fixtures` list may need the doctypes plus a
   `fixtures.txt` per module (check `item_tracking` — it also only used the
   `fixtures` hook, and its fields DID sync, so this is probably not it).

**Commands to finish the fixture investigation** (inside a running bench where
the app has been explicitly installed; these commands do not wire it into the
repository build):
```bash
bench --site frontend migrate
bench --site frontend export-fixtures   # if you edit fixtures
bench --site frontend clear-cache
# verify:
#  GET /api/resource/Custom Field/Sales Invoice-myinvois_status  -> 200
#  GET /api/resource/Client Script/Sales Invoice-MyInvois Actions -> 200
```

## 3. Configuration (site_config.json keys the API reads)

No settings UI yet; `api.get_myinvois_settings()` reads `frappe.conf` (site_config.json):

| Key | Meaning |
|---|---|
| `myinvois_environment` | `Sandbox` (default) or `Production` |
| `myinvois_api_base_url` | optional override (defaults to preprod/prod MyInvois URL) |
| `myinvois_token_endpoint` | optional override |
| `myinvois_client_id` / `myinvois_client_secret` | LHDN client credentials; **absent ⇒ submission is gated off** and the invoice is marked "Pending Validation" with an explicit "not submitted" message |

Set them with:
```bash
bench --site frontend set-config myinvois_environment Sandbox
bench --site frontend set-config myinvois_client_id "<id>"
bench --site frontend set-config myinvois_client_secret "<secret>"
```

## 4. Remaining work (unstarted / partially done)

1. **Finish MyInvois fixture sync** (section 2) and verify the Sales Invoice
   "MyInvois" buttons + Company/Customer/Supplier TIN fields render.
2. **End-to-end test** the Sales Invoice → Validate → Submit flow; confirm the
   gated path (no creds → "Pending Validation", no LHDN call) and the configured
   path (real POST, status updates, rejection handling).
3. **jsQR fallback** for the camera scanner (currently native `BarcodeDetector`
   only; Safari/Firefox fall back to manual entry).
4. Optionally reconcile `Tracked Item` with native ERPNext `Serial No`.
5. Re-run `docs/ASSESSMENT-einvoicing-barcode.md` checks after MyInvois lands.

## 5. Quick facts for the next agent

- Project: this repository, Docker project `comp_demo`, site `frontend`.
- Apps live in the **container** at `/home/frappe/frappe-bench/apps/<app>`; host
  source under `repos/<app>`. The container `apps/` dir is NOT a bind mount —
  sync edits with `docker cp` (or `docker cp` the whole app), then
  `bench build --app <app>` (JS) and `bench --site frontend clear-cache` (Python/hooks).
- `docker compose up -d` HANGS on this host; use `create`+`start` (see `up.ps1`).
- DB is on the `db_data` named volume and persists across `docker restart`.
- Windows→bash quoting is painful (see `docs/WINDOWS-QUOTING.md`); prefer
  `docker exec -w <dir> ... cat <file>` and single-quoted PowerShell strings;
  avoid nested `--args` JSON inline.
- `bench serve` runs as PID 1 (`exec`); `docker restart comp_demo-bench-1`
  restarts it and re-reads `apps.txt`/installed apps.
