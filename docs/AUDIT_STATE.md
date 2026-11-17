# Cleanup audit state — 2026-11-17

Branch `fix/cleanup-Adji`. Executed against the working tree and the running `comp_demo` stack.
Status vocabulary: **Implemented / Tested / Verified / Blocked / Not started**.
"Verified" = a command transcript in this file.

Commits: `ad19680` (P0), `076bb1f` (P1+P2), plus the P3 doc-fact commit.

---

## P0 — Repair

| # | Change | Status |
|---|---|---|
| 1 | `repos/metabase_integration/.../__init__.py` had **no** `__version__` → added | Implemented |
| 1b | **New defect found:** `repos/my_invois/.../__init__.py` shipped `__version__ = " 0.0.1` — an **unterminated string**, so the module failed to import. Rewritten | Implemented |
| 3 | `.env` line 68 (corrupted comment) truncated: **250,318 → 3,954 bytes**, 79 lines preserved | Implemented |
| 7 | `versions.env text eol=lf` added to `.gitattributes`; `env_value()` now does `sub(/\r$/,"")` | Implemented |

**Verified transcript**

```
$ docker exec comp_demo-bench-1 bash -lc "cd /home/frappe/frappe-bench && bench --site frontend version"
barcode_shrdc 0.0.2  ()
erpnext 16.35.0  ()
eu_einvoice 16.3.0  ()
frappe 16.35.0  ()
item_tracking 0.0.2  ()
metabase_integration 0.0.1  ()
my_invois 0.0.1  ()
shopify 0.0.1  ()
exit=0

$ docker compose -p comp_demo --env-file .env --env-file versions.env -f docker-compose.yml config -q
exit=0
```

Note: the container's `my_invois` app is **baked into the image**, not bind-mounted (only 4 app
dirs are mounted), so the live fix was applied with `docker cp` and the host tree was fixed for
the next build. A rebuild will carry it.

## P1 — Dead-code sweep

| Change | Status |
|---|---|
| 108 of 160 `sandbox/scripts/*` moved to `sandbox/scripts/_legacy/` (proven unreferenced) | Implemented / Verified |
| Deleted `sandbox/up.ps1`, `sandbox/scheduler-up.ps1`, `sandbox/docker-compose.yml`, `sandbox/docker-compose.erpnext-fix.yml`, `sandbox/rebuild.sh`, `sandbox/scripts/rebuild-sandbox.sh`, `adji`, `SETUP-GUIDE.docx` | Implemented |
| `.cache/` — 2 ngrok log files still open by a running process; not deleted, now gitignored | Partial |

Reference proof method: every tracked text file (572) was loaded and searched for each script's
basename, skipping the file itself; files with zero hits were quarantined. Result: **52 remain**
(18 launcher-referenced + 34 referenced from docs/agents), 108 dead, 68 pre-existing archived.

`docs/MANIFEST.md` was **deleted**: its counts were stale, it documented the removed
`sandbox/.env.ai-fix`, and it was the last carrier of an `ai-fix` reference. This differs from the
prompt's "regenerate last or delete" only in choosing delete.

## P2 — Kill the ai-fix generation

13 files pointed at the deleted launcher; all rewritten to the canonical root `up.ps1`.
`sandbox/.env.ai-fix` / `.env.fix` mentions removed; `ai-fix-*.sh` → `fix-*.sh`.

**Verified**

```
$ git grep -c -E 'ai-fix' -- .                    # 0 files
$ git grep -c -E '/metabase_dashboard' -- .       # 0 files
$ Test-Path on all 23 keep-list paths             # missing=0
```

**Regression caught and fixed:** the blanket path rewrite also turned the CI guard
"the retired `up.ps1` must not come back" into a guard against the **canonical** root launcher
(`.github/workflows/ci.yml`), and reworded `up.ps1`'s own help so it described itself as dead.
Both were corrected: the guard now checks `sandbox/up.ps1` again, and the help text names the
retired file explicitly.

**Second regression caught and fixed:** replacing the literal `4041` repo-wide corrupted
`repos/shopify-shrdc-v16-fixed/shopify/orders.json` (the substring sat inside a Shopify order
token) and two legitimate ngrok port-probe lists. All four files were reverted with
`git checkout --`; the data file is byte-identical to `HEAD` again. Only the two genuinely wrong
doc claims were changed.

## P3 (partial) — One source of truth for facts

| Fact | Change |
|---|---|
| ngrok API port | `AGENTS.md` 4041 → **4040** |
| Metabase route | `Customisations.md` `/metabase_dashboard` → **`/metabase`** |
| Frappe/ERPNext versions | `MILESTONES.md:51` 16.53.0/16.52.1 and `ASSESSMENT-einvoicing-barcode.md:16` 16.53/16.54 → **16.35.0** |

Remaining `4041` occurrences are intentional: a fallback default in `up.ps1:236` and two
"probe both ports" loops (`verify-all.ps1`, `shopify-setup/setup-shopify-erpnext.ps1`), plus
`orders.json`, which is vendored third-party data.

## Not started — and why

| Item | Reason |
|---|---|
| Defect 2 — regenerate `.env` from `.env.example` | Needs secrets re-entered by the owner; the corrupted line is truncated, but `ENVIRONMENT`, `TZ`, `ERPNEXT_ADMIN_PASSWORD`, `WEBHOOK_SINK_PORT`, `FORWARD_URL` are still missing and `DB_TMPFS_SIZE`/`ERPNEXT_VERSION` still obsolete. **Ask-first.** |
| Defect 5 — bench container on untagged `6e4bb0e551ea` | Requires container recreate/rebuild. **Ask-first.** |
| Defect 6 — Node-RED on `:latest` vs pinned 5.0.9 | Requires container recreate. **Ask-first.** |
| Defect 8/11/16 — divergent launchers, service counts, `up-linux.sh` pull-then-build | Out of the executed scope (P4/P5). |
| P4 — EOL hardening beyond `versions.env` | Only the two `env_value`/`.gitattributes` pieces landed. |
| P5 — consolidate 74 docs to ~12 | Not attempted; large, and would conflict with the un-repaired `.env`/counts. |
| P6 — structural move | Explicitly out of bounds without a direct request. |
| Verification harness (`up-linux.sh` with stubbed docker on WSL) | No usable Linux shell confirmed on this host; the compose-config and keep-list checks were used instead. |

## Count corrections to the prompt's ground truth

| Claim | Measured |
|---|---|
| `sandbox/scripts/*` non-archived = 175 | **160** (108 dead, 52 alive) |
| `bench version` crashes on `metabase_integration` | True, but it **also** crashed on `my_invois` — two defects, and `my_invois` was an invalid Python file |
| `MANIFEST.md` "barcode 52 files" | not re-measured |

## Open questions

1. Should `.env` be regenerated now (owner must supply secrets), or left truncated-but-working?
2. Recreate the bench container onto `comp_demo-bench:v16` and Node-RED onto 5.0.9 in one
   `compose up -d`? Both are ask-first and were deliberately left alone.
3. `lowdefy/` (19 files) is still undecided — document or archive.
4. Is `_legacy/` (108 files) to be deleted outright after one release, or kept as an archive?
