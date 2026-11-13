# Plan — stabilise, modularise and future-proof the ERPNext v16 integrations demo

**Repo:** `SHRDC_Internship/erpnext-v16-integrations-demo` (origin `msf4-0/erpnext-v16-integrations-demo`)
**Status of this document:** proposal in progress. P0.1/P0.2 and P0.4/P0.5 are implemented in this checkout; provenance recovery and modularisation remain.
**Evidence:** every claim below was verified in this working tree on 2026-11-13. Commands used are in
[Appendix F](#appendix-f--commands-used-to-build-the-evidence-base) so you can re-run them.

---

## Table of contents

1. [Objective](#1-objective)
2. [Definition of done](#2-definition-of-done)
3. [Evidence base: what is actually true today](#3-evidence-base-what-is-actually-true-today)
4. [Target architecture](#4-target-architecture)
5. [Phase plan](#5-phase-plan)
6. [Decision log](#6-decision-log)
7. [Risk register](#7-risk-register)
8. [Rollback strategy](#8-rollback-strategy)
9. [Appendix A — drift and modularity gates](#appendix-a--drift-and-modularity-gates)
10. [Appendix B — verification / health matrix](#appendix-b--verification--health-matrix)
11. [Appendix C — documentation ownership map](#appendix-c--documentation-ownership-map)
12. [Appendix D — registry schema reference](#appendix-d--registry-schema-reference)
13. [Appendix E — deferred and out of scope](#appendix-e--deferred-and-out-of-scope)
14. [Appendix F — commands used to build the evidence base](#appendix-f--commands-used-to-build-the-evidence-base)

---

## 1. Objective

The stack works, but it is only *known* to work on one Windows machine, through PowerShell, and the
proof lives in prose. Six custom apps were imported from other interns' repositories with their git
history stripped, so nobody can say which code is theirs, which is ours, or what to update when they
push. Every new app currently has to be wired by hand into five different files.

This plan does three things, in this order:

1. **Stabilise** — make the documentation, configuration and version pins tell the truth, and make the
   build refuse to silently run on demo credentials in production.
2. **Recover provenance** — establish, file by file, which app code came from where and which deltas
   are ours, *before* any restructuring. This is the gate: doing it after would destroy unpushed work.
3. **Modularise** — turn the apps into a declarative, fetch-based section where adding an app is one
   registry entry and a patch directory, and no app knows about another app's internals.

Extensibility is the point: after this plan, a new integration is a review of *one YAML file and one
patch set*, not an archaeological dig through `up.ps1`.

---

## 2. Definition of done

| # | Goal | Measured by |
|---|---|---|
| D1 | One command rebuilds and verifies, on both OS | Clean clone → `up.sh` **and** `up.ps1` → identical green report |
| D2 | Docs cannot drift | Every path, version and durability claim is generated or gate-checked; no obsolete ephemeral-database claims, machine-specific absolute paths, or unpinned versions |
| D3 | Provenance is complete | `apps/PROVENANCE.md` accounts for every file in every app; the pinned base + patches reproduces the current trees byte-for-byte |
| D4 | Apps are independent | Every app passes its own tests on stock `frappe` + `erpnext` + **only** its declared `requires` |
| D5 | Adding an app is one edit | A throwaway app installs by adding one registry entry (+ a patch dir if it is a fork); `tools/apps.py check` stays green |
| D6 | Failures are loud | Missing secret / missing app / missing dependency produces a specific error, never an `is_ajax` mask or a silent skip |

**Non-goal:** new features. `my_invois` fixture repair and the Metabase stub are *quarantined*, not fixed
(see §6, decision 3).

---

## 3. Evidence base: what is actually true today

### 3.1 Inventory

- 41 commits on `main`, working tree clean, single branch (`origin` = `git@github.com:msf4-0/erpnext-v16-integrations-demo.git`).
- 7 services in `docker-compose.yml`: `bench`, `db`, `redis-cache`, `redis-queue`, `node-red`, `scheduler`, `metabase`.
- **6 app directories under `repos/`: 292 files tracked as plain blobs. None has a `.git`. No `.gitmodules`.
  No submodule entries in the index.**

That last line is the whole problem: the apps are not dependencies, they are *copies*, and the
provenance was destroyed when they were copied.

### 3.2 Who installs what (and the app that nobody does)

| App | Dir | Baked in image | Bind-mounted | Installed by build | Quarantined | Where the code runs today |
|---|---|---|---|---|---|---|
| `barcode_shrdc` | `repos/barcode-shrdc-v16-fixed` | yes (`bench.Dockerfile:42`) | yes (`docker-compose.yml:107`) | `up.ps1` step 7 | no | mount wins over image |
| `shopify` | `repos/shopify-shrdc-v16-fixed` | yes (`:43`) | no | `up.ps1` step 7 | no | image layer only |
| `eu_einvoice` | `repos/eu_einvoice` | yes (`:44`) | no | `up.ps1` step 7b | no | image layer only |
| `item_tracking` | `repos/item_tracking` | no | yes (`:101`) | `up.ps1` step 7b-2 | no | mount + runtime install |
| `metabase_integration` | `repos/metabase_integration` | no | yes (`:102`) | `ensure_metabase_app.ps1` | **yes** | stub (6 files); original controllers lost |
| `my_invois` | `repos/my_invois` | **no** | **no** | **no** | **yes** | written; installer missing; fixtures never synced; see [`docs/HANDOFF.md`](docs/HANDOFF.md) §2 |

`my_invois` source is present in the repository, but no build or startup entry
point installs it. The prior site installation recorded in `docs/HANDOFF.md`
was historical; its fixtures did not materialize, and a clean build does not
install it. Keep the app quarantined until installation wiring and fixture sync
are repaired.

### 3.3 Provenance: verified upstream diffs

All three upstreams are reachable. Cloned to `/tmp/opencode/prov` and diffed against the vendored trees.

| App | Upstream + ref | Delta measured | Interpretation |
|---|---|---|---|
| `barcode_shrdc` | `msf4-0/ERPNext-Barcode-Integration`, `origin/v16` = `b79b4d6` (2026-09-24, "Fix barcode_shrdc for ERPNext v16…") | **10 additions / 10 modifications**: `barcode_render.py` (232 L), `label.py` (75), `validators.py` (71), `patches/`, `public/js/`, `requirements.txt`, `fixtures/client_script.json`, refactored `barcode_printing.py`/`.js`/`.json`, `hooks.py`, `__init__.py`, `patches.txt`, 4 fixtures; upstream-only `fixtures/custom_script.json` dropped (v15+ conversion) | Our work is **unpushed**. The whole Pillow renderer and the M9b server-side scan rule exist only here |
| `shopify` | `msf4-0/shopify-ERPnext` = `975267a` (main) | `auth.py` (254 L) + `utils.py` added; **18 of 19 modules modified** | Effectively a rewrite. The 24 h-token minting — the project's headline fix — exists only here |
| `eu_einvoice` | `alyf-de/eu_einvoice`, `develop` = `28d18b0` (2026-11-11) | 42 files differ | **Base unknown.** `pyproject.toml` declares `docs_branch = "version-16-hotfix"`, and `__version__ = "16.3.0"`; the diff against `develop` is probably branch skew, not our patches. Must be re-diffed against the matching ref before classifying |
| `item_tracking` | none recorded (`recipe: ./repos/item_tracking`; `Customisations.md` says "local app") | n/a | First-party, 42 files |
| `my_invois` | none recorded ("local app") | n/a | First-party, 11 files |
| `metabase_integration` | `rover96/frappe-metabase` (prose only) | n/a | **6 files** — a re-scaffold after the original code was lost (`PERSISTENCE.md` §4). Not upstream, not complete |

The legacy `custom_manufacturing` and `chat_widget` entries were removed from
the active app inventory because their source trees are absent. The
`custom_manufacturing` customisation rows remain historical only; no app is
protected from rollback by name.

### 3.4 Wiring is spread across five places

Adding or changing one app means editing:

1. `docker-compose.yml` — bind mounts (3 apps) + the 60-line inline `command:` bash
2. `bake/bench.Dockerfile` — `COPY` (3 apps) + a hardcoded `.pth` loop (3 apps) + `pip install`
3. `up.ps1` — `$reposDir` staging (~L359-393) and 26 `Write-Step` blocks with hand-numbered labels (`7b/11`, `7b-2/11`, `7c/11`…)
4. `sandbox/recipes/<app>.yaml` — app facts, in a schema only `install-app.sh` reads
5. `Customisations.md` — the human registry

Plus the docs. `repos/` is referenced **110 times across 36 files**. `sandbox/recipes/README.md`
points at `../../APP-SOURCES.md`, **which does not exist**.

### 3.5 Apps are not independent

- `item_tracking/item_tracking/events.py:91` and `…/doctype/tracked_item/tracked_item.py:169` import
  `barcode_shrdc` internals. **Undeclared hard dependency** — `item_tracking` cannot install alone, and
  nothing records that. (It already has its own `raster.py` renderer, so the coupling is avoidable.)
- `metabase_dashboard.py` / `.html` live in `item_tracking/www/` — a BI page inside the tracking app.
- Three apps write `Custom Field` / `Client Script` / `Property Setter` fixtures onto overlapping
  standard doctypes (`Item`, `Delivery Note`, `Stock Entry`) with no ownership rule.
- `barcode_shrdc` exports **`Role`, `Role Profile`, `Workflow`, `Workflow State`, `Workflow Action`**.
  On a non-demo site that overwrites security configuration.

### 3.6 Config and documentation drift

| Issue | Evidence |
|---|---|
| DB durability | `docker-compose.yml` and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) establish the `db_data` named volume; conflicting ephemeral-database claims have been corrected |
| Project path | Older docs and agent permissions contained machine-specific Windows paths; current commands resolve from the repository root |
| Version pins | [`versions.env`](versions.env) is authoritative for ERPNext, MariaDB, Redis, Node-RED, and Metabase image tags; documentation points to it |
| `.env.example` ↔ compose | `.env.example` now documents the Metabase settings and no longer contains obsolete `DB_TMPFS_SIZE` |
| Demo secrets | `.env.example` retains development-only defaults; the host validator and bench startup guard refuse production startup while demo/default or placeholder credentials remain |
| No healthchecks | zero `healthcheck:` keys in the compose file; `depends_on` is start-order only, so `bench` races `db` and `redis` |
| Encoding | UTF-8 mojibake (`Ã¢â‚¬â€`, `Ãƒâ€”`) in `AGENTS.md` (10), `MANIFEST.md` (13), `docs/MILESTONES.md` (27) |
| Verification | `verify-all.ps1` is PowerShell-only; tests are spread across `repos/*/test_*.py`, `item_tracking/self_test.py` + `stock_test.py`, `sandbox/scripts/{barcode_test,test_barcode_feature,verify_item_tracking_fix}.py`, and `scheduler/ui-tests/*.mjs`, with three different invocation styles |

### 3.7 Licensing and hygiene

- The three upstream apps include `license.txt`; `barcode_shrdc`'s file says MIT but its README says
  GPLv3, so its redistribution terms need resolution. The three first-party apps declare no license.
- `repos/barcode-shrdc-v16-fixed/barcode_shrdc/_aifix_token2.py` was an unreferenced operator script
  that cleared `tabUser.api_key/api_secret` and printed a freshly minted key:secret pair. P0.6 removed it.
- `bake/bench.Dockerfile` copies the whole repo as build context (`.`) including `scheduler/` (14 MB).

### 3.8 Runtime reality of this checkout

Nothing here has ever run on this machine: **no `.env`**, **no `pwsh`/`powershell`**, `comp_demo` has
never been built. The only Docker stack running is an unrelated `frappe_docker` project. Every claim of
"working" refers to the SHRDC Windows host.

---

## 4. Target architecture

### 4.1 Layout

```
apps/                              # THE custom-app section; everything app-shaped lives here
├── registry.yaml                  # single source of truth (schema: Appendix D)
├── apps.lock                      # resolved SHAs + patch hashes; reproducible + offline
├── PROVENANCE.md                  # app → upstream → base ref → our patches → owner → licence
├── patches/
│   ├── barcode_shrdc/0001-*.patch
│   └── shopify/0001-*.patch
├── first_party/
│   ├── item_tracking/             # real source, not a fork; authored here
│   └── my_invois/                 # real source, quarantined (enabled: false)
└── .vendor/                       # GITIGNORED — fetched at pinned SHA, patches applied
    ├── barcode_shrdc/  shopify/  eu_einvoice/  metabase_integration/

platform/                          # hosts the apps; contains no app names
├── docker-compose.yml             # no bind mounts, no inline bash
├── docker-compose.apps.yml        # GENERATED from the registry
├── bake/bench.Dockerfile          # ARG-driven; includes the generated apps layer
├── bake/apps.layer.Dockerfile     # GENERATED: COPY + .pth + pip
└── bake/entrypoint.sh             # the 60-line bash, now a real testable file

tools/                             # one implementation, runs on Windows and Linux
├── apps.py                        # fetch | verify | install | emit | check
├── up.py  verify.py  health.py
├── up.sh  up.ps1                  # 3-line wrappers
└── check-drift.sh                 # CI entry point

docs/APPS.md                       # GENERATED — never hand-edited
docs/ARCHITECTURE.md               # the one authoritative description
```

`repos/` is removed from git: **−292 files, −11 MB**. The build fetches from the interns' origins.

### 4.2 Why fetch instead of vendor

| | Vendored (`repos/`) | Fetched (`apps/.vendor` + lock) |
|---|---|---|
| Who owns a file | unknowable | `PROVENANCE.md` + `git log` in the upstream clone |
| Updating an app | re-copy by hand, lose history | bump one SHA in `apps.lock` |
| Patent duplicate code | 292 files of it | one registry row |
| Reproducible offline | yes | yes — `--offline` reads the cache populated by `fetch` |
| Blast radius | everything | one row |

The Windows host's network is flaky (`YARN_FETCH_RETRIES` exists for a reason), so fetch is lazy and
cached, never re-cloned per build, and `make-bundle.ps1` can zip `.vendor/` for offline handoff.

### 4.3 The provenance-first rule

**No file moves until §3.3 is resolved.** The barcode renderer, the scan validator, and the Shopify
token minting exist in no remote. A naive "point at the origin repos" would delete ~650 lines of barcode
work and rewrite Shopify back to a 401-ing bridge — and nothing in the repo would report the loss,
because there is no history to diff against.

The safety net is a byte-exact reproduction test:

```bash
tools/apps.py fetch --all
diff -rq --exclude=__pycache__ apps/.vendor/barcode_shrdc repos/barcode-shrdc-v16-fixed/barcode_shrdc
```

Empty output = nothing was lost. Non-empty = stop, do not proceed.

---

## 5. Phase plan

Each phase is independently mergeable and leaves the Windows host green. Effort estimate assumes no
surprises in P1.

| Phase | Outcome | Effort | Blocking? |
|---|---|---|---|
| P0 | Truth, safety, licensing | 0.5 d | no |
| P1 | Provenance recovered, deltas pushed | 1–1.5 d | **yes — gates P2+** |
| P2 | Fetch-based apps section | 1 d | no |
| P3 | Generated wiring | 1 d | no |
| P4 | Apps decoupled | 1 d | no |
| P5 | Dual-OS harness | 1 d | no |

---

### P0 — Truth and safety

**Goal:** the repo stops lying, and a production boot cannot silently use demo credentials.
**No file moves, no renames, zero runtime change.** Every task is reversible with `git revert`.

#### P0.1 Create `docs/ARCHITECTURE.md` (authoritative)

Contents: the 7 services and their real dependencies; **DB is `db_data` volume, durable across
restart** (with the earlier RAM-backed-storage history and *why* it changed, from `bake/README.md` §Track 2b); port map;
app inventory from §3.2; the canonical project location; image pins from `versions.env`.

- [x] Write it.
- [x] Add a header to the conflicting docs pointing to `docs/ARCHITECTURE.md`.

#### P0.2 Kill the durability contradiction

Replace every obsolete restart-loss claim with the `db_data` reality, keeping the
historical note only in `ARCHITECTURE.md` and `bake/README.md` instead of twelve repetitions.

- [x] `AGENTS.md`, `README.md`, `MANIFEST.md`, `PERSISTENCE.md`, `docs/MILESTONES.md` (2 sites),
      `docs/SETUP-GUIDE-for-existing-build.md`, `shopify-setup/README.md`, `lowdefy/PLAN.md`,
      `.opencode/skills/erpnext-test-sandbox/SKILL.md`, `.opencode/agents/erpnext-test-runner.md`
- [x] Gate: the requested Markdown durability search returns only `docs/ARCHITECTURE.md` and
      `bake/README.md` (the historical section).

#### P0.3 Canonicalise the path

- [x] Docs and scripts use repo-relative paths; the Windows-only quoting example and historical host note are labeled.
- [x] `opencode.json` permissions use repo-relative globs (`*up.ps1*`, `*tools/up*`).
- [x] Path gate: only `docs/WINDOWS-QUOTING.md` and MANIFEST's historical host note match.

#### P0.4 Single version pin

- [x] Add root `versions.env` with pins for ERPNext, MariaDB, Redis, Node-RED,
      Metabase, and the Frappe series.
- [x] `bake/bench.Dockerfile`: `ARG ERPNEXT_BASE` + `FROM ${ERPNEXT_BASE}`.
- [x] `docker-compose.yml` and the supported scripts load image tags from `versions.env`.
- [x] Docs point to `versions.env` as the authoritative set of component image tags.
- [ ] Verify which ERPNext is *actually* installed on the live site (`bench --site frontend list-apps`)
      and record it in `ARCHITECTURE.md` as observed-vs-pinned.
- [ ] Gate: `grep -rnE "16\.[0-9]+\.[0-9]+" docs/ README.md AGENTS.md | grep -v versions.env` → only
      inside generated/observed blocks.

#### P0.5 `.env.example` ↔ compose parity, and the secrets policy (per your answer)

Keep working defaults so a future developer can boot instantly; make production refuse them.

- [x] Add supported Metabase keys to `.env.example`; delete `DB_TMPFS_SIZE`.
- [x] Add `ENVIRONMENT=development`.
- [x] The bench startup command prints a
      **startup banner** listing every secret still on its demo default.
- [x] If `ENVIRONMENT=production` **and** any default is in use → **exit 1** with the exact key names to
      fix. No stack, no silent fallback.
- [ ] Automated Compose-variable parity gate remains for P3; the validator's focused policy tests pass.

#### P0.6 Licensing and hygiene

- [x] Preserve the upstream `license.txt` files for the three upstream apps (verified against
      `/tmp/opencode/prov`).
- [x] Add root `THIRD-PARTY.md` with app, origin, license, and redistribution status.
      (Root, not `apps/` — it describes the whole repository.)
- [x] Flag `eu_einvoice` GPL-3.0-or-later and require its source and license to remain available.
- [x] Delete the unused `repos/barcode-shrdc-v16-fixed/barcode_shrdc/_aifix_token2.py`; the separate
      token-generation logic remains unchanged, and no replacement was needed for an unreferenced module.
- [ ] Gate: upstream license files exist for the three upstream apps. Three first-party apps have
      no declared license; do not invent one. Confirm their rights holder and license before claiming
      one file per app or redistributing those apps.

#### P0.7 Honesty in `Customisations.md`

`Customisations.md` calls itself the "single source of navigation" and is wrong in three ways.

- [x] Remove the absent `custom_manufacturing` and `chat_widget` app entries; delete the
      `chat_widget` protected-app policy.
- [x] `my_invois`: status is **`written, installer missing, fixtures never synced`**, linked to
      `docs/HANDOFF.md` §2 and its §3.2 app row.
- [x] `metabase_integration`: status is **`stub (6 files); controllers lost`**.
- [x] Add a `Quarantined` column so an incomplete app cannot be read as installed.

#### P0.8 Repair the encoding

- [x] Re-encode `AGENTS.md`, `MANIFEST.md`, `docs/MILESTONES.md` to clean UTF-8
      (`Ã¢â‚¬â€` → `—`, `Ã¢â€ â€™` → `→`, `Ãƒâ€”` → `×`, `Ã¢â€°Ë†` → `≈`).
- [x] Gate: `grep -c 'Ã' AGENTS.md MANIFEST.md docs/MILESTONES.md` → 0.

#### P0.9 Delete or create `APP-SOURCES.md`

`sandbox/recipes/README.md` links to it; it does not exist.

- [x] Create it as a pointer to `PROVENANCE.md` (P1) for now, with the three verified upstream URLs.

**P0 exit criteria**

```bash
# Markdown database-durability wording gate: only ARCHITECTURE.md + bake/README.md
grep -rc 'Ã' AGENTS.md MANIFEST.md docs/MILESTONES.md   # all zero
test -f docs/ARCHITECTURE.md && test -f THIRD-PARTY.md  # both exist
# start the stack with ENVIRONMENT=production and a default password -> exits 1 with a key name
```

---

### P1 — Provenance recovery (the gate)

**Goal:** be able to say, for every file in every app, where it came from and who owns the delta.
**Nothing moves in this phase.** Upstream clones live in `/tmp`; only `PROVENANCE.md` and
`apps/patches/**` are committed.

#### P1.1 Resolve each base ref by minimal delta

For forks, the base is the upstream commit that makes our delta smallest.

```bash
mkdir -p /tmp/opencode/prov && cd /tmp/opencode/prov
git clone https://github.com/msf4-0/ERPNext-Barcode-Integration barcode
git clone https://github.com/msf4-0/shopify-ERPnext               shopify

# barcode: candidate refs, pick the minimum
cd barcode
for ref in origin/v16 origin/master; do
  git fetch -q --depth 50 origin "${ref#origin/}"; git checkout -q FETCH_HEAD
  echo "$ref -> $(diff -rq barcode_shrdc <OURS>/repos/barcode-shrdc-v16-fixed/barcode_shrdc | wc -l) diffs"
done
```

Verified result to reproduce: `origin/v16` = `b79b4d6` leaves **10 files of our work**;
`origin/master` = `e885970` leaves more. `origin/v16` is the base.

For `eu_einvoice` the candidates are `version-16`, `version-16-hotfix`, `develop`, and the `v16.3.0`
tag — our `__version__` is `16.3.0` and `pyproject.toml` declares `docs_branch = "version-16-hotfix"`.
Loop the same way and take the minimum; **the residual is our patch set, and it must be reviewed, not
assumed**.

- [ ] Record each chosen ref (full 40-char SHA) in `PROVENANCE.md`.
- [ ] For `item_tracking` / `my_invois`: record "no upstream; first-party, authored in this project".
- [ ] For `metabase_integration`: clone `rover96/frappe-metabase`, confirm the 6-file stub is a
      re-scaffold, and record "upstream available; current tree is a stub".

#### P1.2 Extract and commit our deltas as patches

```bash
mkdir -p apps/patches/barcode_shrdc
diff -ruN --exclude=__pycache__ --exclude='*.pyc' \
     /tmp/opencode/prov/barcode/barcode_shrdc \
     repos/barcode-shrdc-v16-fixed/barcode_shrdc \
  > apps/patches/barcode_shrdc/0001-v16-fixes-and-renderer.patch
```

Split into **reviewable, single-purpose** patches rather than one blob, matching the existing commit
history so a reviewer can follow:

- [ ] `barcode_shrdc`: (a) v16 ports — whitelist, unsaved-QR, save crash, dead APIs; (b) `validators.py`
      server-side scan rule (M9b); (c) `barcode_render.py` + `label.py` Pillow renderer, no rlPyCairo;
      (d) per-unit serial labels (`get_serial_summary` / `ensure_serials`); (e) fixtures +
      `fixtures/client_script.json` conversion; (f) 60 mm label size.
- [ ] `shopify`: (a) `auth.py` token minting + Redis cache; (b) `utils.get_shopify_access()` as the single
      choke point and the 18-module threading; (c) numeric coercion for empty payload fields;
      (d) guest-customer naming.
- [ ] `eu_einvoice`: whatever survives the minimal-delta diff (expected small).

#### P1.3 Push the deltas back to the forks

You own `msf4-0`, so this needs nobody else.

- [ ] `barcode_shrdc` → branch `v16-shrdc` in `msf4-0/ERPNext-Barcode-Integration`, one commit per patch
      above, tag `v16-shrdc-2026-11`.
- [ ] `shopify` → branch `v16-shrdc` in `msf4-0/shopify-ERPnext`, tag `v16-shrdc-2026-11`.
- [ ] Restore `license.txt` in the same commits where it was dropped.
- [ ] Record the resulting SHAs in `PROVENANCE.md` **and** `apps.lock`.
- [ ] If push access is unavailable (decision 1), stop at patches and record the fork as
      `pending-upstream`; P2 still works, but the app cannot be updated from upstream.

#### P1.4 First-party decision (decision 2)

- [ ] Either create `msf4-0/item-tracking` and `msf4-0/my-invois` as real repos with history, or declare
      them first-party in-repo under `apps/first_party/`. **Recommended: in-repo** — they are small,
      they are ours, and an extra repo per app is overhead for a demo.

**P1 exit criteria** — the safety net:

```bash
# for each app, pinned base + committed patches must reproduce the current tree exactly
tools/apps.py fetch --only barcode_shrdc --base-from <ref> --apply apps/patches/barcode_shrdc
diff -rq --exclude=__pycache__ --exclude='*.pyc' \
     apps/.vendor/barcode_shrdc repos/barcode-shrdc-v16-fixed/barcode_shrdc
# EXPECTED: no output
```

Repeat for `shopify`, `eu_einvoice`, `metabase_integration`. **If any diff is non-empty, stop** — a file
was missed and P2 would delete it.

- [ ] `PROVENANCE.md` lists every app with: upstream URL, base SHA, patch list, owner, licence, and
      whether the delta is pushed.

---

### P2 — The fetch-based apps section

**Goal:** `repos/` leaves git; apps are declared, fetched, patched and verified by one tool.

#### P2.1 Write the registry

- [ ] `apps/registry.yaml` (schema in [Appendix D](#appendix-d--registry-schema-reference)) with all six
      apps. Seed `enabled: false` for `my_invois` and `metabase_integration` (decision 3), and
      `fixtures.scope: demo` for `barcode_shrdc`.
- [ ] Preserve today's hard dependency explicitly: `item_tracking.requires: [barcode_shrdc]`
      (P4 turns it into an optional capability).

#### P2.2 `tools/apps.py`

One Python implementation — **Python is already a prerequisite** (`sandbox/node-red/build-flows.py`), so
this is the only cross-OS code path that needs maintaining.

- [ ] `fetch [--all|--only NAME] [--offline]` — resolve registry → shallow clone at `ref` into
      `apps/.vendor/<name>` → apply `patches/<name>/*.patch` in lexical order → verify file hashes →
      write `apps.lock`.
- [ ] `verify` — re-hash the vendor tree against `apps.lock`; non-zero on drift.
- [ ] `install [--site frontend]` — iterate by `order`, run `bench install-app`, and **fail loudly** if
      an enabled app is missing (today `item_tracking` failure is a `Write-Warn`).
- [ ] `emit` — write `platform/docker-compose.apps.yml`, `platform/bake/apps.layer.Dockerfile`,
      `docs/APPS.md`.
- [ ] `check` — the gates in [Appendix A](#appendix-a--drift-and-modularity-gates).
- [ ] `--offline` reads `apps/.vendor` only; error message names the missing app and the `fetch`
      command that fixes it.

#### P2.3 Move the trees, once, mechanically

Do this in **one commit**, immediately followed by the P2 exit verification.

```bash
git checkout -b feat/apps-section
git mv repos/item_tracking         apps/first_party/item_tracking
git mv repos/my_invois             apps/first_party/my_invois
git rm -r repos/barcode-shrdc-v16-fixed repos/shopify-shrdc-v16-fixed \
          repos/eu_einvoice repos/metabase_integration
rm -rf repos/
```

- [ ] Sweep the **110 `repos/` references across 36 files** — scripted, then eyeballed:
      `docker-compose.yml`, `bake/bench.Dockerfile`, `up.ps1`, `sandbox/up.ps1`, `sandbox/rebuild.sh`,
      `sandbox/scripts/ai-fix-install.sh`, `sandbox/recipes/*.yaml`, all docs, all five agents, the
      test-sandbox skill, `Customisations.md`.
- [ ] Delete `sandbox/recipes/<app>.yaml` for the six apps once `registry.yaml` supersedes them; keep the
      recipe schema only for genuinely external apps (it is still useful).
- [ ] Move loose debris: `diag_bp.py`, `diag_console.py` → `tools/diag/`; `sandbox/verify_item_tracking_fix.py`,
      `sandbox/scripts/barcode_test.py`, `sandbox/scripts/test_barcode_feature.py` →
      `apps/first_party/item_tracking/tests/` or delete.
- [x] Record that `_aifix_token2.py` was deleted and must not reappear through vendoring; no active
      source referenced the module.

#### P2.4 Offline and bundle

- [ ] `make-bundle.ps1`: include `apps/.vendor/` and `apps.lock` so the Windows host can rebuild with no
      network.
- [ ] Document the cache location and the `fetch --offline` failure message in `docs/ARCHITECTURE.md`.

**P2 exit criteria**

```bash
tools/apps.py fetch --all && tools/apps.py verify     # lock matches vendor
tools/apps.py check                                   # all gates green
git ls-files repos | wc -l                            # 0
du -sh .git                                           # should shrink after gc, not grow
docker compose config >/dev/null && echo config-ok    # the generated override resolves
```

---

### P3 — Generated wiring

**Goal:** adding an app touches one registry entry. Nothing else.

#### P3.1 Emit the wiring

- [ ] `platform/docker-compose.apps.yml` — the bind mounts, one per `mount: true` app, with a generated
      header (`# GENERATED by tools/apps.py emit — do not edit`).
- [ ] `platform/bake/apps.layer.Dockerfile` — `COPY` lines for baked apps, the `.pth` loop, and one pip
      layer per app from its `pip:` list. Replaces the hardcoded 3-app list in `bench.Dockerfile`.
- [ ] `docker-compose.yml` gains `include:` (Compose v2.20+) or an explicit `-f` in the wrappers.
- [ ] Shrink the build context: `.dockerignore` excludes `scheduler/`, `.git`, `apps/.vendor`,
      `sandbox/`, `docs/`.

#### P3.2 Extract the inline bash

60 lines of `command:` with manual `$$` escaping is unlintable and untestable.

- [ ] → `platform/bake/entrypoint.sh`, plain bash, no escaping hacks, `shellcheck`-able.
- [ ] Keeps today's behaviour exactly: DB-grant self-heal, `.pth` re-registration, `/assets` symlinks,
      `bench schedule` + `bench worker`, `exec bench serve --port 8000`.
- [ ] Adds: the `ENVIRONMENT`/default-secret policy from P0.5, and a startup **health gate** that blocks
      `bench serve` until MariaDB and Redis answer (60×2 s, bounded, then fail loudly — no more
      `is_ajax` masking).

#### P3.3 Replace the numbered install steps

`up.ps1` has 26 `Write-Step` calls with hand-numbered labels (`7b-2/11`) that must be edited by hand for
every app. Replace the app section with:

```powershell
& python tools/apps.py install --site $Site
if ($LASTEXITCODE -ne 0) { Write-Error "app install failed - see above"; exit 1 }
```

- [ ] Keep the *non-app* steps (Shopify sync, demo masters, planner, flow, tunnel, webhooks) as-is; they
      are demo-data concerns, not app concerns.
- [ ] `up.ps1` app step count drops from 11 labelled steps to 1.

#### P3.4 Healthchecks and ordering

- [ ] `db`: `mariadb-admin ping`; `redis-*`: `redis-cli ping`; `bench`: HTTP 200 on `/api/method/ping`
      with `start_period: 120s`.
- [ ] `depends_on` with `condition: service_healthy` on `bench`, `scheduler`, `node-red`, `metabase`.

#### P3.5 Generate the docs

- [ ] `docs/APPS.md` from the registry: name, kind, source, ref, patches, requires, verify doctype,
      status, install order.
- [ ] `THIRD-PARTY.md` from `LICENSE` files + registry.
- [ ] Banner in every generated file so nobody hand-edits it.

**P3 exit criteria**

```bash
# the extensibility test
mkdir -p apps/patches/hello_world
# add ONE registry entry for hello_world (first_party), nothing else
tools/apps.py emit && tools/apps.py check && git diff --stat
# EXPECTED: only generated files change; no hand-edited file is touched
docker compose config | grep hello_world   # the mount appears without editing compose
```

---

### P4 — Decouple the apps

**Goal:** every app passes its own tests against stock v16 + only its declared `requires`.

#### P4.1 Break `item_tracking → barcode_shrdc`

`item_tracking` already has `doctype/tracked_item/raster.py` (PNG with SVG fallback). The two import
sites (`events.py:91`, `tracked_item.py:169`) exist only to reach `barcode_shrdc`'s label creation.

- [ ] Add `apps/first_party/item_tracking/.../label_bridge.py`:
      try `barcode_shrdc` → build a `Barcode Printing` doc; except `ImportError` → log an info message and
      return `None` so the stock-entry flow continues without labels.
- [ ] Registry: move `barcode_shrdc` from `requires:` to `optional:`.
- [ ] Test: install `item_tracking` on a site **without** `barcode_shrdc`; a Stock Entry submit must
      succeed with no labels and no traceback.

#### P4.2 Move the Metabase page home

- [ ] `apps/first_party/item_tracking/www/metabase_dashboard.{py,html}` →
      `metabase_integration/www/` (restore its controllers from `rover96/frappe-metabase` if pins allow).
- [ ] Fix the route references and `Customisations.md` row 24.
- [ ] If the restore is out of reach, **delete the page and record it as dropped** — a page whose
      controller lives in the wrong app is worse than no page.

#### P4.3 Fixture ownership matrix

Three apps write fixtures onto `Item`, `Delivery Note`, `Stock Entry`.

- [ ] Produce `docs/FIXTURE-OWNERSHIP.md`: doctype → field/script → owning app → collision rule.
- [ ] Rule: one owner per field; a second app that needs a field documents it and does not redefine it.
- [ ] Enforce with a `check` rule (A7).
- [ ] `barcode_shrdc.fixtures.scope = demo` gates `Role`, `Role Profile`, `Workflow`, `Workflow State`,
      `Workflow Action` so a production install cannot overwrite security config. `always` scope keeps
      only `Print Format`, `Report`, `Custom Field`, `Client Script`, `Property Setter`.

#### P4.4 Declare the remaining coupling

- [ ] `my_invois` reads `frappe.conf` keys; add them to `.env.example` documentation and to the registry
      `config:` block so they are visible without reading `api.py`.
- [ ] `check` rule A6 fails on any cross-app import outside `requires`/`optional`.

**P4 exit criteria**

For each enabled app: `bench --site <s> install-app <app>` on a fresh site with only
`frappe`+`erpnext`+declared requires, then `bench --site <s> run-tests --app <app>` → green.

---

### P5 — Dual-OS stability harness

**Goal:** one command, either OS, same report.

#### P5.1 One implementation

- [ ] `tools/up.py` — the 11 steps expressed once. Ports the logic from `up.ps1` (45 KB) and `setup.ps1`
      (57 KB), which stay as thin wrappers so the SHRDC Windows workflow is unchanged.
- [ ] Preserve the host workaround: **`docker compose up -d` hangs on the Windows host → use `create` +
      `docker start`.** Encode it as a flag chosen by trying `up -d` with a timeout, or by
      `--compose-mode=create` (default on Windows).
- [ ] `tools/up.sh` / `tools/up.ps1`: 3 lines each — locate Python, call `tools/up.py`, exit with its code.

#### P5.2 Verification matrix

- [ ] `tools/verify.py` replaces `verify-all.ps1` as the source of truth; the `.ps1` becomes a wrapper.
- [ ] Implements [Appendix B](#appendix-b--verification--health-matrix), driven by the registry: per-app
      verify doctype, per-app `app_include_js` asset URLs, ping, queue, planner health, Node-RED node
      count, Metabase health, and a **failure message naming the app**, not just a red `X`.
- [ ] Exit code 1 on any failure; a machine-readable `--json` mode for CI.

#### P5.3 Tests where the code lives

- [ ] Per app: `bench --site <s> run-tests --app <name>`.
- [ ] `item_tracking`: promote `self_test.py` + `stock_test.py` to `tests/` with a documented runner.
- [ ] Planner: keep `scheduler/ui-tests/*.mjs`; call the read-only one from `verify.py`.
- [ ] `tools/check-drift.sh` for CI (lint only, seconds).

#### P5.4 CI

- [ ] `.github/workflows/check.yml`: `python tools/apps.py check` + `docker compose config` +
      shellcheck on `entrypoint.sh`. No image build (too heavy for a demo repo).
- [ ] Optional nightly full build on a self-hosted runner if you ever get one.

**P5 exit criteria**

```bash
# on this Linux box, from a clean clone
git clone … && cp .env.example .env && ./tools/up.sh && ./tools/verify.py
# on the Windows host, the documented two commands still work
powershell -File .\up.ps1 ; powershell -File .\verify-all.ps1
# same report, same exit code
```

---

## 6. Decision log

| # | Question | Decision | Basis |
|---|---|---|---|
| 1 | Rename `repos/` → `apps/`? | **Yes**, as part of P2, but only after P1 proves the delta is preserved | Your answer: repos are other interns' apps dumped in; they should be referenced and pulled from origin |
| 2 | Where do first-party apps live? | **`apps/first_party/` in this repo** (assumed) | Small, ours, and an extra GitHub repo per app is overhead. Override if you prefer separate repos |
| 3 | `my_invois` / `metabase_integration`? | **Quarantine honestly** — `enabled: false`, status `incomplete`, excluded from the green report, fix as follow-up | Your answer |
| 4 | Secrets defaults | **Keep dev defaults; warn at startup; hard-fail when `ENVIRONMENT=production`** | Your answer |
| 5 | Target OS | **Both.** Python driver + thin `.ps1`/`.sh` wrappers | Your answer: "it should work on both OS" |
| 6 | Push access to `msf4-0` forks | **Assumed yes** (both forks and this repo are under `msf4-0`) | If no: patches only, fork marked `pending-upstream` |
| 7 | `_aifix_token2.py` | **Deleted**; no replacement was needed because it was unreferenced | It printed a freshly minted key:secret pair |
| 8 | Verification authority | Linux build as the dev loop, Windows host stays the reference build (smoke-tested per phase) | Practical: that is where the current stack exists |

---

## 7. Risk register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | **A delta file is missed and P2 deletes it** | Medium | **Critical** — loses the renderer / token minting with no history to recover from | P1 byte-exact reproduction gate; `diff -rq` must be empty before P2 starts. `git tag pre-apps-registry` as a tagged snapshot |
| R2 | The true `eu_einvoice` base cannot be identified | Medium | Medium — patches become one large blob | Try every branch/tag, take the minimum delta; if still ambiguous, `git add -A` our tree as `first_party`-style `fork-snapshot` with the ambiguity documented |
| R3 | Upstream pushes back / force-pushes over our delta | Low | High | Pin by **full SHA** in `apps.lock`, never a branch; tag our push |
| R4 | Windows host breaks mid-transition (network, `up -d` hang) | Medium | High | `--offline` + `make-bundle.ps1` ships `.vendor/`; `.ps1` wrappers preserved; per-phase Windows smoke test |
| R5 | Container recreate disturbs the site | Low | Medium | `db_data` is a volume; recreate + `bench migrate`; take a `mysqldump` before P2 |
| R6 | Fetch adds a network dependency to a demo that must boot offline | Medium | Medium | Cache + lock + bundle archive; `fetch` runs once, builds read `.vendor` |
| R7 | GPL-3.0 obligation mishandled | Low | Medium (legal) | Restore licences in P0; `THIRD-PARTY.md`; do not relicense |
| R8 | Generated files get hand-edited and drift returns | Medium | Medium | `# GENERATED` banner + `check` rule that regenerates into a temp dir and diffs |
| R9 | `my_invois` stays broken and someone reads it as working | High | Low | Quarantine flag in registry + `Customisations.md` + `verify.py` output |

---

## 8. Rollback strategy

| Phase | Rollback | Data risk |
|---|---|---|
| P0 | `git revert <sha>` — docs/config only | none |
| P1 | Nothing in the runtime changed; `git revert` drops `PROVENANCE.md`/patches. Fork branches/tags are additive | none |
| P2 | `git revert` restores `repos/` from the tagged snapshot `pre-apps-registry`. `apps.py fetch --offline` keeps working from cache | none — code paths only |
| P3 | Delete `platform/docker-compose.apps.yml` + the generated Dockerfile layer, restore the previous `command:` block from git | none |
| P4 | Each decoupling is one commit; revert restores the hard dependency (still functional) | none |
| P5 | Old `up.ps1`/`setup.ps1` remain until P5's final commit; revert returns to them | none |

**Pre-flight before P2** (the only phase that deletes files):

```bash
git tag pre-apps-registry
docker exec comp_demo-db-1 sh -c 'exec mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --all-databases' \
  > /tmp/comp_demo-pre-apps.sql
```

---

## Appendix A — drift and modularity gates

Implemented in `tools/apps.py check`. Any failure = non-zero exit = CI red.

| ID | Rule | Rationale |
|---|---|---|
| A1 | Every registry app resolves to a directory | no phantom apps |
| A2 | `app_name` in `hooks.py` == registry `name` | catches copy-paste forks |
| A3 | Every `enabled` app appears in the generated compose + Dockerfile layer | the `my_invois` class of bug |
| A4 | Every `${VAR}` in compose exists in `.env.example` | the `METABASE_*` class of bug |
| A5 | No `repos/` path anywhere; no machine-specific absolute paths outside Windows-specific docs | the drift class of bug |
| A6 | **No cross-app import outside declared `requires`/`optional`** | the modularity rule that keeps this maintainable |
| A7 | One owner per `Custom Field` / `Client Script` / `Property Setter` | fixture collisions |
| A8 | Every app has a `LICENSE` and a `THIRD-PARTY.md` row | compliance |
| A9 | No file matching `_*token*`, `*.env`, `*secret*` inside `apps/` | secrets in source |
| A10 | Every app declares `verify.doctype` and that doctype exists in its tree | verification cannot silently no-op |
| A11 | Generated files are byte-identical to a fresh `emit` | kills hand-editing |
| A12 | `apps.lock` SHAs are full 40-char and the vendor tree matches their hashes | reproducibility |

---

## Appendix B — verification / health matrix

`tools/verify.py`, driven by the registry.

| Check | Scope | Pass |
|---|---|---|
| `GET /api/method/ping` | stack | 200 `pong` |
| Per-app verify doctype | each enabled app | REST 200 for `verify.doctype` |
| Per-app static asset | each `app_include_js` | HTTP 200 + expected marker string |
| `bench --site <s> list-apps` | stack | every enabled app present |
| Installable standalone | each app (P4 gate) | fresh site + stock v16 |
| `run-tests --app` | each app | exit 0 |
| Queue alive | redis-queue | worker heartbeat < 60 s |
| Planner | `:3001/api/health` | `Server is running` |
| Planner schedule | `:3001/api/schedule` | WOs/JCs/stations > 0 |
| Node-RED | `:1880/flows` | node count matches `sandbox/node-red/flows.json` |
| Webhooks | 3 endpoints | POST 200 |
| Metabase | `:3005/api/health` | `{"status":"ok"}` |
| Barcode render | `get_barcode_image` | real PNG/SVG bytes, not an error string |
| `apps.lock` | repo | hashes match `.vendor` |
| Gates A1–A12 | repo | `check` green |

Every failure prints **which app** and the one command that usually fixes it.

---

## Appendix C — documentation ownership map

| Fact | Single owner | Everyone else links |
|---|---|---|
| Services, ports, DB durability, version triple | `docs/ARCHITECTURE.md` | link |
| App inventory, source, ref, status | `docs/APPS.md` (**generated**) | link |
| Provenance and licences | `apps/PROVENANCE.md`, `THIRD-PARTY.md` | link |
| How to build / daily commands | `README.md` | link |
| Milestone history and known gaps | `docs/MILESTONES.md` (narrative, frozen) | link |
| Customisation registry | `Customisations.md` | link |
| Fixture ownership | `docs/FIXTURE-OWNERSHIP.md` | link |

Rule: a fact may be *stated* in one place and *linked* everywhere else. Any file repeating a version
number or a path is a bug.

---

## Appendix D — registry schema reference

```yaml
version: 1

defaults:
  frappe_series: "16"
  order: 100
  enabled: true
  mount: true

apps:
  - name: barcode_shrdc              # MUST equal app_name in hooks.py (gate A2)
    kind: fork                       # upstream | fork | first_party
    enabled: true
    order: 10
    source:
      url: https://github.com/msf4-0/ERPNext-Barcode-Integration
      ref: <40-char-sha>             # NEVER a branch (gate A12)
      subdir: barcode_shrdc          # path inside the clone that is the app package
    patches: patches/barcode_shrdc   # applied in lexical order
    pip: [reportlab, qrcode, pillow]
    requires: []                     # hard deps; install order derived, cycles are an error
    optional: []                     # feature-detected at runtime (P4)
    verify:
      doctype: "Barcode Printing"
      asset: /assets/barcode_shrdc/js/scanner_barcode_patch.js
    fixtures:
      scope: demo                    # demo = includes Role/Workflow; always = safe subset
    config: []                       # frappe.conf keys the app reads
    notes: |
      Why this ref, what the patches do, and what bites next time.

  - name: item_tracking
    kind: first_party
    order: 20
    source: {local: first_party/item_tracking}
    requires: []
    optional: [barcode_shrdc]        # P4: was a hard import
    verify: {doctype: "Tracked Item"}

  - name: my_invois
    kind: first_party
    enabled: false                   # QUARANTINED — installer missing, fixtures never synced
    order: 50
    source: {local: first_party/my_invois}
    verify: {doctype: "Sales Invoice"}
    quarantine_reason: docs/HANDOFF.md#2
```

`apps.lock` is generated, never hand-edited:

```yaml
generated_by: tools/apps.py fetch
barcode_shrdc:
  ref: <40-char-sha>
  patches: [{path: patches/barcode_shrdc/0001-*.patch, sha256: …}]
  tree_sha256: …
```

---

## Appendix E — deferred and out of scope

| Item | Why deferred |
|---|---|
| Fixing `my_invois` fixture sync | Feature work; quarantined with a written reason |
| Restoring `metabase_integration` controllers | Depends on upstream pins; P4 either restores or drops the page |
| `custom_manufacturing`, `chat_widget` | Not in this repo; P0 corrects the docs |
| Rewriting the planner SPA | Out of scope — it works |
| Barcode/QR rendering changes | Out of scope — P4 only changes *who imports it* |
| jsQR fallback for the camera scanner | Feature work (HANDOFF §4.3) |
| Serial-number reconciliation with native `Serial No` | Feature work (HANDOFF §4.4) |
| PowerShell → Python for the demo-data seeders | Not needed; P5 only routes the entrypoints |
| A real database migration strategy | `db_data` volume + documented `mysqldump` is proportionate for a demo |

---

## Appendix F — commands used to build the evidence base

```bash
# history and state
git log --pretty=format:'%h %ad %s' --date=short | head -45
git status --short

# the vendoring problem
for d in repos/*/; do test -d "$d/.git" && echo "$d has git" || echo "$d NO GIT"; done
git ls-files repos | wc -l                       # 292
git ls-files --stage repos | awk '$1=="160000"'  # empty: no submodules
ls .gitmodules                                   # absent

# wiring spread
grep -rn "repos/" --include=*.ps1 --include=*.yml --include=*.sh --include=*.md . | wc -l   # 110
grep -c "Write-Step" up.ps1                                                                 # 26
grep -rn "my_invois" up.ps1 docker-compose.yml bake/                                        # nothing

# provenance (upstreams are reachable)
git clone --depth 50 https://github.com/msf4-0/ERPNext-Barcode-Integration /tmp/opencode/prov/barcode
git clone --depth 50 https://github.com/msf4-0/shopify-ERPnext               /tmp/opencode/prov/shopify
git clone --depth 1  https://github.com/alyf-de/eu_einvoice                  /tmp/opencode/prov/eu
cd /tmp/opencode/prov/barcode && git fetch --depth 1 origin v16 && git checkout FETCH_HEAD
diff -rq barcode_shrdc <repo>/repos/barcode-shrdc-v16-fixed/barcode_shrdc
diff -rq /tmp/opencode/prov/shopify/shopify <repo>/repos/shopify-shrdc-v16-fixed/shopify
diff -rq /tmp/opencode/prov/eu/eu_einvoice <repo>/repos/eu_einvoice/eu_einvoice | wc -l   # 42

# drift
# Markdown database-durability wording gate
grep -rc 'Ã' AGENTS.md MANIFEST.md docs/MILESTONES.md
grep -E '^[A-Z_]+=' .env.example | sed 's/=.*//' | sort > /tmp/a
grep -oE '\$\{[A-Z_]+' docker-compose.yml | tr -d '${' | sort -u > /tmp/b && comm -13 /tmp/a /tmp/b

# coupling
grep -rn --include=*.py -E 'from (barcode_shrdc|item_tracking|shopify)' repos/
```

---

*End of plan. Start with P0; do not start P2 until P1's `diff -rq` gate is empty.*
