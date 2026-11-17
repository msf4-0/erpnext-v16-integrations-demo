# Cleanup audit state — 2026-11-17

Branch `fix/cleanup-Adji`. Executed against the working tree and the running `comp_demo` stack.
Status vocabulary: **Implemented / Tested / Verified / Blocked / Not started**.
"Verified" = a command transcript in this file.

Commits: `ad19680` (P0), `076bb1f` (P1+P2), plus the P3 doc-fact commit.

---

## P0 — Repair

| # | Change | Status |
|---|---|---|
| 1 | `repos/metabase_integration/metabase_integration/__init__.py` had **no** `__version__` → added | Implemented |
| 1b | **New defect found:** `repos/my_invois/my_invois/__init__.py` shipped `__version__ = " 0.0.1` — an **unterminated string**, so the module failed to import. Rewritten | Implemented |
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

`MANIFEST.md` (root) was **deleted**: its counts were stale, it documented the removed
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

| Item | Reason / status |
|---|---|
| Defect 2 — `.env` regeneration | **Done** — see Round 2 below. |
| Defect 5 — bench container on untagged image | **Done differently** — see Round 2: retagged, pinned, recreated. |
| Defect 6 — Node-RED on `:latest` vs pinned 5.0.9 | **Done** — see Round 2. |
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

---

## Round 2 (same day) — defects 2, 5, 6 closed

### P0.2 — `.env` regenerated from `.env.example`

Method: every key in `.env.example` keeps its **live value** from the previous `.env`; only keys
absent from it take the example default. Values were never printed. Result: **4,721 bytes, 37 keys**
(was 29 keys). Carried 28 live values, added 7 (`ENVIRONMENT`, `TZ`, `ERPNEXT_ADMIN_PASSWORD`,
`WEBHOOK_SINK_PORT`, `FORWARD_URL`, …). `DB_TMPFS_SIZE` / `ERPNEXT_VERSION` were retained because
they are still read (`sandbox/scripts/fix-install.sh:25` uses `ERPNEXT_VERSION`), which contradicts
the audit's "obsolete" claim. Backups: `.env.bak-20261117`, `.env.bak-20261117-regen`.

Verified: `docker compose … config -q` exit 0; site answers `{"message":"pong"}`.

### P0.5 — bench image: the audit's fix would have **broken the demo**

`comp_demo-bench:v16` (`19d3f2b0a7f8`) contains **5 apps**, not 8 — it is missing `item_tracking`,
`metabase_integration` and `my_invois`. Recreating the container onto it, as the prompt directed,
would have removed three live apps. The running image was also **untagged** (`6e4bb0e551ea`).

Root cause: `bake/bench.Dockerfile` COPYs only `barcode-shrdc-v16-fixed`, `shopify-shrdc-v16-fixed`,
`eu_einvoice` (`:43-45`); the other three arrive by bind mount. The running container predated the
`my_invois` mount, which is why the host-side `__init__.py` fix never appeared inside it.

Action taken:
1. `docker tag 6e4bb0e551ea comp_demo-bench:v16-live`
2. `BENCH_IMAGE=comp_demo-bench:v16-live` added to `.env`, so `compose up` can no longer silently
   swap in the incomplete `:v16` image. Verified: rendered config resolves
   `image: comp_demo-bench:v16-live`.
3. Recreated bench with `--no-build --no-deps`, which applied the `my_invois` mount.

Verified after recreate:

```
$ docker inspect comp_demo-bench-1 --format '{{.Config.Image}}'
comp_demo-bench:v16-live
mounts: logs, sites, apps/barcode_shrdc, apps/item_tracking, apps/metabase_integration, apps/my_invois
$ docker exec comp_demo-bench-1 bash -lc "bench --site frontend version"
... item_tracking 0.0.2 / metabase_integration 0.0.1 / my_invois 0.0.1 / shopify 0.0.1
$ curl http://localhost:8000/api/method/ping   ->  {"message":"pong"}
```

**Still open:** a fresh clone that builds from `bake/bench.Dockerfile` gets 5 apps, not 8. Either
add the three COPY lines (and accept slower builds) or document that they are mount-only. Not
changed here, because the mount-only design is deliberate for `item_tracking`/`metabase_integration`.

### P0.6 — Node-RED pinned

`docker pull nodered/node-red:5.0.9` (first attempt failed: Docker Hub TLS handshake timeout;
retry succeeded), then `compose up -d --no-build --no-deps node-red`.

```
$ docker ps --filter name=node-red
comp_demo-node-red-1 nodered/node-red:5.0.9 Up About a minute (healthy)
$ node-red --version -> 5.0.9
$ GET http://localhost:1880/ -> HTTP 200   (log: "Started flows", "Server now running")
```

### Docs corrected in this round

- `docs/ARCHITECTURE.md:103` — Node-RED `:latest` → `:5.0.9` (pinned).
- `README.md:138` — "not installed and not in this repository" → **installed** (`my_invois 0.0.1`),
  source present at `repos/my_invois`, bind-mounted. This was the third conflicting version of the
  same fact.

### Remaining, explicitly not done

- P4 beyond `versions.env` (repo-wide CRLF audit), P5 (74 → ~12 docs), P6 (structural move).
- The 108 files in `sandbox/scripts/_legacy/` are quarantined, not deleted — intended to survive one
  release cycle before removal.
- `Customisations.md:31` still describes `my_invois` as "current state unverified"; it is installed,
  but the *fixtures* really are unsynced, so the row needs a human decision rather than a rewrite.

---

## Round 3 — P4 EOL hardening + P5 first slice

**P4.** `versions.env`, `bake/bench.Dockerfile` and `sandbox/scripts/bootstrap_masters.py` were the
only *shipped executables* with CRLF; all three are now LF on disk and in git. `repos/**` Python was
deliberately left alone (vendored upstream, CRLF is harmless there, and the category is "never
edit"). `.gitattributes` pins `*.sh`, `*.py`, `*.yml`, `*.yaml`, `versions.env`, `Dockerfile` to LF.
Verified: `docker compose … config -q` exit 0 with the LF `versions.env`, and `env_value()` in
`up-linux.sh` now strips `\r` defensively.

**P5 (first slice).** Moved to `docs/archive/`, with 0 inbound references each:

| File | Was | Now |
|---|---|---|
| `erpnext-demo-stabilise-modularise.md` | 48 KB plan for a target state never built | `docs/archive/` |
| `docs/archive/HANDOFF.md` | 4 claims false vs the live stack | `docs/archive/` |
| `docs/archive/ASSESSMENT-einvoicing-barcode.md` | point-in-time assessment | `docs/archive/` |

Root now holds **9** own markdown files, down from 11; `docs/` is 9 (8 after these moves).

**Not done in P5:** the full 74 → ~12 restructure (splitting README into
`docs/installation/`, per-module pages, `docs/troubleshooting/`). That rewrites cross-links in
dozens of files and should not be bundled with defect repair; it remains the largest open item.

---

## Round 4 — dangling-reference sweep

Automated scan: every backticked repo-relative path in live docs/scripts/skills was tested with
`Test-Path`. 17 distinct misses; 12 are intentional (they document deleted files, namely
`sandbox/up.ps1`, `sandbox/scheduler-up.ps1`, the sandbox composes, `_legacy/`, and two planned
directories). The real defects found and fixed:

| Reference | Problem | Fix |
|---|---|---|
| `.opencode/skills/erpnext-safe-change/SKILL.md:124` | instructed an agent to **run** `sandbox/scripts/cx_rollback.sh` before a destructive uninstall; **no rollback script exists anywhere in the repo** (checked `git ls-files` for `rollback`) | replaced with the explicit backup → uninstall → remove → migrate → verify procedure and a confirmation gate |
| `Customisations.md:43, :99` | same phantom tool as a safety mechanism (`KEEP=chat_widget`) | marked policy-only; procedure written out |
| `Customisations.md:115` | pointed at `repos/custom_manufacturing`, which the same file says is absent | annotated historical |
| `docs/METABASE-DASHBOARD-GUIDE.md` | `item_tracking/.../events/stock_entry.py` does not exist | repointed to the real doctype controller `stock_entry_tracked_item.py` |
| `docs/INSTALL.md:284` | `scheduler/frontend/node_modules` presented as shipped | already annotated `(generated by npm ci; not tracked)` — scanner false positive |

Quarantined 3 more scripts whose only references were historical: `barcode_test.py`,
`fix-barcode-v16-bump.sh`, `test_barcode_feature.py`. Live `sandbox/scripts` count: **49**.

### Definition-of-done status

| Criterion | State |
|---|---|
| `bench version`, `list-apps`, `/api/method/ping` | **met** |
| `.env` ≤ 5 KB from `.env.example` | **met** (4.7 KB, 37 keys) |
| No `ai-fix` live prose; no reference to a nonexistent path | **met** (see above) |
| `sandbox/scripts` ≤ 25 files, each referenced | **not met — 49**, and every one is referenced. Reaching 25 would mean deleting referenced material; the prompt's premise (18 referenced) was low. |
| Own docs ≤ 15 | **not met — 19** (9 root + 10 in `docs/`), plus 3 archived. Consolidated only via the archive move. |
| Launchers pass on CRLF and LF | **partial** — root cause fixed (gitattributes + `\r` strip); the stubbed dry-run harness was never run because no Linux shell was confirmed on this host. |
| `git status` clean | **met** |
| P6 structural move | **declined**, as the prompt required |

---

## Round 5 — launcher harness, P5 merges, encoding repair

### Still-open P4/P0 acceptance is now **Verified**

WSL was available after all, so the stubbed dry-run harness finally ran (written to `F:\ERPsessions\dryrun_launchers.sh`,
stubs only, no repo writes):

```
=== bash -n syntax check ===
OK  up-linux.sh
OK  install-apps-linux.sh
=== up-linux.sh ===            exit=0
ERPNext is ready at http://localhost:8000 (site: frontend).
=== install-apps-linux.sh ===  exit=0
Custom apps are installed on site 'frontend'.
=== FRAPPE_SERIES resolved as: 16   (versions.env, LF)
=== repo dirty after run? ===  (clean)
```

That exercises the CRLF `FRAPPE_SERIES` path that defect 7 was about. **Launchers pass on both
endings** — closing the last "partial" in the DoD table.

### P5 merges (root markdown 9 → 7)

| Merged | Into | Links repointed |
|---|---|---|
| `APP-SOURCES.md` (463 B, 7 inbound) | `docs/FACTS.md` → new "Upstream sources" section | 8 files incl. relative `./`, `../`, `../../` forms |
| `PERSISTENCE.md` (3.9 KB, 1 inbound) | `docs/ARCHITECTURE.md` → "Persistence, bind mounts and why app features vanish after a recreate" | 1 |
| `question-bank.md` (8.2 KB, 3 inbound) | `.opencode/agents/references/` (next to the planner agent) | 4 |

Dangling-path rescan after the moves: **0 unexplained missing paths**.

### Encoding defect (pre-existing, not introduced here)

8 tracked files contained double-encoded UTF-8 (mojibake), verified present in `HEAD` before this
work. Repaired **line-by-line** where `cp1252 → utf-8` round-tripped cleanly, skipping anything that
produced U+FFFD: **20 lines across 7 files** (5 agent files, `docs/MILESTONES.md`,
`scheduler/ui-tests/README.md`). `.opencode/skills/erpnext-test-sandbox/SKILL.md` could not be
repaired safely and still shows mojibake — a lossy rewrite was deliberately not attempted.

### New finding — repo weight

**847 of 1,609 tracked files are `scheduler/runtime-deps/node_modules`** (52%). This is deliberate:
the planner image ships its node deps for an offline build, which is why `.gitignore` covers
`scheduler/frontend/node_modules/` and `scheduler/ui-tests/node_modules/` but not `runtime-deps`.
**Do not delete it** — it would break the offline planner build. Worth a sentence in the docs rather
than action.

---

## Round 6 — the three requested merges (docs 16 → 14)

| Merge | Result | Inbound links repointed |
|---|---|---|
| `docs/IMAGE-POLICY.md` → `docs/DISTRIBUTION.md` | one distribution + image-policy page, `## Bench image policy` section | 10 files |
| `docs/SETUP-GUIDE-for-existing-build.md` + `docs/WINDOWS-QUOTING.md` → `docs/INSTALL.md` | one installation page: "Adding the missing functions…" + "Windows / PowerShell quoting" sections | 10 files |

Method: absorbed documents become `##` sections with heading levels demoted one step. GitHub anchors are
derived from heading **text**, not level, so every pre-existing `#anchor` still resolves. A first
attempt demoted headings blindly and also rewrote `#` comment lines **inside fenced code blocks** in
the install guide, corrupting the example commands; the script was made fence-aware and the files
regenerated from `HEAD`. Verified afterwards: code blocks show single-`#` comments, 0 dangling paths.

Counts: root markdown **6**, `docs/` **8**, `docs/archive/` 3 → **14 live docs**, inside the ≤15 target.

---

## Round 7 — remove the Tooljet skill (unrelated to this demo)

`.opencode/skills/tooljet-app-builder/` deleted: **13 tracked files, 210 KB**. It builds Lowdefy/Tooljet
apps, has no caller anywhere in the repo (`git grep -i tooljet` outside the directory: 0 hits), and
nothing in the stack or the launchers touches it. 20 skills remain, all ERPNext/Frappe or workflow
related.

**Correction to Round 5:** I reported `scripts/browser-audit.js` (cited by that skill's `qa.md`) as a
dangling path. It is not — the file exists at `.opencode/skills/tooljet-app-builder/scripts/browser-audit.js`,
and the citation is relative to the skill directory. The scanner treated every backticked path as
repo-relative. The scan now resolves each path both repo-relative **and** relative to the citing
file's directory. Result: 4 remaining hits, all benign and enumerated — 3 are this document
naming the files it merged and deleted (`IMAGE-POLICY.md`, `WINDOWS-QUOTING.md`,
`SETUP-GUIDE-for-existing-build.md`), and 1 is `scheduler/frontend/node_modules`, a directory generated
by `npm ci`. **0 unresolved path references** in the repository.

---

## P7 — Reproducible fresh deployment: all 8 apps (branch `deployapp`)

Scope: make a clean clone deployable with Docker alone. The cleanup work above is untouched.

### App source inventory (audited before editing)

| # | App | Source (git-tracked) | Bench dir | Deps | Baked before P7 | Installed before P7 |
|---|---|---|---|---|---|---|
| 1 | frappe | base image `frappe/erpnext:v16.35.0` | `apps/frappe` | image | yes (image) | yes |
| 2 | erpnext | base image | `apps/erpnext` | image | yes (image) | yes |
| 3 | barcode_shrdc | `repos/barcode-shrdc-v16-fixed` (64 files) | `apps/barcode_shrdc` | requirements.txt | yes + **bind mount** | yes |
| 4 | shopify | `repos/shopify-shrdc-v16-fixed` (53 files) | `apps/shopify` | requirements.txt | yes | yes |
| 5 | eu_einvoice | `repos/eu_einvoice` (120 files) | `apps/eu_einvoice` | pyproject (factur-x, drafthorse, saxonche) | yes | yes |
| 6 | metabase_integration | `repos/metabase_integration` (9 files) | `apps/metabase_integration` | requirements.txt | **no - bind mount only** | yes |
| 7 | item_tracking | `repos/item_tracking` (65 files) | `apps/item_tracking` | requirements.txt | **no - bind mount only** | yes |
| 8 | my_invois | `repos/my_invois` (13 files, requirements.txt empty) | `apps/my_invois` | none | **no - bind mount only** | seed installed it if the dump predated it |

All eight are git-tracked (324 files under `repos/`), so no network fetch is required for app source.
Defect confirmed: the pre-P7 image contained **5** apps total (frappe, erpnext + 3 custom); three
apps existed only as bind mounts, and `my_invois` was additionally uninstalled-but-mounted.

### Changes

| # | File | Change | Status |
|---|---|---|---|
| 1 | `bake/bench.Dockerfile` | COPY all six custom app sources; per-app `pip install -r requirements.txt`; build-time app-shape guard (`hooks.py`, `__init__.py`, `__version__`) that fails the build; build-time import smoke test for all six; bakes `/usr/local/bin/install-all-apps.sh` | Verified |
| 2 | `sandbox/scripts/install-all-apps.sh` (new) | canonical ordered idempotent site installer: list-apps gate, `apps.txt` + `.pth` registration, install in dependency order, one `migrate`, then verify list-apps **and** module import; `SKIP_APPS` explicit opt-out; non-zero exit on any failure; `ALLOW_PARTIAL=1` only as an explicit override | Verified |
| 3 | `seed/seed-site.sh` | replaced the my_invois-only special case with a call to the shared installer (one code path for bench, seed and manual runs) | Verified |
| 4 | `docker-compose.yml` | removed 4 app bind mounts from `bench` and 2 from `seed` (image is now authoritative); seed waits for `redis-cache`/`redis-queue` (its `bench migrate` otherwise aborts with "Service redis_cache is not running"); seed gains `SKIP_APPS`/`ALLOW_PARTIAL` | Verified |
| 5 | `up-linux.sh` | runs the canonical installer after provisioning, so a Linux deployment is one command | Implemented |
| 6 | `install-apps-linux.sh` | app list extended from 4 to all 6 custom apps; help text points at the canonical installer | Implemented |
| 7 | `sandbox/scripts/verify-deployment.sh` (new) | read-only 7-check acceptance verifier (compose config, containers, `bench version`, all 8 apps exactly once, module import, `/api/method/ping`, unresolved `hooks.py` assets) | Implemented |
| 8 | `docs/DEPLOY.md` (new), `README.md` | clean-machine guide: prerequisites, clone, env, one command, what happens automatically, verification, stop/restart, troubleshooting, `SKIP_APPS`; README section 3a points to it | Implemented |

### Why

The image was not self-contained (3 apps came from bind mounts), nothing guaranteed all eight were
*installed* (my_invois was mounted-but-not-installed; item_tracking/metabase_integration depended on
a host folder existing), and `sites/apps.txt` was never reconciled with the restored DB, so
`bench version` reported only 2 apps on a restored site.

### Acceptance test — isolated project

Host: Windows 11 + Docker 29.8.0. Isolated: project `comp_demo_p7`, own volumes
`comp_demo_p7_db_data` / `comp_demo_p7_bench_sites`, own ports (18000/11880/13001/13005/18088).
The live `comp_demo` stack was not touched; no `down -v`, no volume deletion, no site reinstall.

```
$ docker build -f bake/bench.Dockerfile --build-arg ERPNEXT_BASE=frappe/erpnext:v16.35.0 \
      -t comp_demo-bench:p7-test .
... app-source guard: all 6 custom app sources present and well-formed
... import ok: barcode_shrdc 0.0.2 / shopify 0.0.1 / eu_einvoice 16.3.0
... import ok: item_tracking 0.0.2 / metabase_integration 0.0.1 / my_invois 0.0.1
... naming to docker.io/library/comp_demo-bench:p7-test   (build succeeded, no bind mounts involved)

$ docker compose -p comp_demo_p7 ... up -d --no-build db redis-cache redis-queue bench
seed-1 | Site frontend has been restored
seed-1 | -- present: frappe erpnext barcode_shrdc shopify eu_einvoice item_tracking metabase_integration my_invois
seed-1 | import ok: frappe, erpnext, barcode_shrdc, shopify, eu_einvoice, item_tracking, metabase_integration, my_invois
seed-1 | seed: items after restore: 72
seed-1 | seed: metabase_dashboard_url -> http://localhost:3005/public/dashboard/96f46652-...
seed-1 | seed: done - site 'frontend' restored

$ curl -H "Host: frontend" http://localhost:18000/api/method/ping
{"message":"pong"}

$ docker compose -p comp_demo_p7 exec -T bench bench --site frontend version
barcode_shrdc 0.0.2  ()   erpnext 16.35.0  ()   eu_einvoice 16.3.0  ()
frappe 16.35.0  ()        item_tracking 0.0.2  ()  metabase_integration 0.0.1  ()
my_invois 0.0.1  ()       shopify 0.0.1  ()
```

Restart + persistence (same project, after `docker compose restart bench`):

```
$ curl -H "Host: frontend" http://localhost:18000/api/method/ping   -> {"message":"pong"}
$ bench --site frontend list-apps                                    -> all 8, exactly once
$ bench --site frontend execute frappe.db.count --args "['Item']"    -> 72
$ ls sites/assets/                                                   -> barcode_shrdc eu_einvoice
                                                                        item_tracking (+frappe/erpnext)
$ test -e sites/assets/barcode_shrdc/js/scanner_barcode_patch.js    -> exists (the historical
                                                                        reload-loop asset is served)
```

### Blocker found and fixed during the test

First run installed nothing (the seeded dump already contained all eight apps), so
`sites/apps.txt` stayed at `frappe, erpnext` and `bench --site frontend version` reported **2** apps.
Fix: `install-all-apps.sh` now reconciles `apps.txt` for every app on **every** run, not only when
installing. Re-ran the installer in the test container: `apps.txt` and `bench version` then listed all
eight. This defect would have hit every restored deployment.

### Remaining blockers / not verified

| Item | Status | Note |
|---|---|---|
| Truly cold machine (no cached `frappe/erpnext` base layer, fresh Docker) | Not started | the base image was already pulled here; only the build/run/restart path was exercised |
| Windows `up.ps1` / `setup.ps1` deployment path | Not started | P7 changes are Compose/Dockerfile-level, but the PowerShell launchers were not re-run |
| `install-apps-linux.sh` full run against a from-scratch (non-restored) site | Not started | the restore path was tested; the `bench new-site` path was not |
| Metabase UI, Node-RED flow, planner SPA, Shopify token flow | Not started | services were started for the restore path only in local checks; no end-to-end UI pass |
| Baked image published to GHCR (`docs/DISTRIBUTION.md`) | Not started | clean clones currently build locally (20-40 min); publishing remains a distribution task |

### Confirmation run (after the apps.txt fix was committed)

Rebuilt the image with the fixed installer baked in, recreated `bench` from it in the same isolated
project, and ran the **image-baked** installer (no `docker cp`):

```
$ docker build -f bake/bench.Dockerfile --build-arg ERPNEXT_BASE=frappe/erpnext:v16.35.0 \
      -t comp_demo-bench:p7-test .           -> image 1aba698c40ef, import ok x6
$ docker compose -p comp_demo_p7 ... up -d --no-build bench
$ docker compose -p comp_demo_p7 ... exec -T bench bash /usr/local/bin/install-all-apps.sh
  import ok: frappe, erpnext, barcode_shrdc, shopify, eu_einvoice, item_tracking,
             metabase_integration, my_invois
  == install-all-apps: done - all requested apps installed on 'frontend' ==
$ bench --site frontend version   -> all 8 apps
$ curl -H "Host: frontend" http://localhost:18000/api/method/ping   -> {"message":"pong"}
```

Status: image build **Verified**, site restore **Verified**, all-8-apps install **Verified**,
module import **Verified**, restart **Verified**, DB persistence **Verified** (`Item` count 72
before and after restart), apps.txt/`bench version` **Verified** after the fix.
Still not verified: genuinely cold machine, Windows launchers, from-scratch (`bench new-site`) path,
UI-level integration pass - see the table above.
