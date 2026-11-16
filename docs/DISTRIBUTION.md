# Distributing comp_demo to other machines

The goal: a colleague clones the repo, runs one command, and has a working
demo in ~10 minutes — with **no local Docker build** and no knowledge of this
machine.

This document is the acceptance contract for that goal. It also records what is
already true, what is blocked, and the exact steps to finish.

---

## 1. The one slow step, and why it is slow

`bake/bench.Dockerfile` produces a **3 GB** image containing Frappe, ERPNext v16
and five custom apps. Building it takes **25–40 minutes** on a laptop and is the
reason setup "never gets past the setup phase" on a fresh machine.

CI already builds and pushes that image to GHCR:

| Ref | Kind | Status |
|---|---|---|
| `ghcr.io/msf4-0/comp-demo-bench:v16` | moving tag (what compose/start.ps1 use) | published by `publish-image` |
| `ghcr.io/msf4-0/comp-demo-bench:v16.1`, `:v16.2` | immutable, for pinning | published |
| `ghcr.io/msf4-0/comp-demo-bench:<git-sha>` | per-commit (ci.yml, `main`) | published |

**The blocker is package visibility, not the build.** The package is private, so
an anonymous `docker pull` gets `401 unauthorized`; compose then falls back to
the 25–40 minute build. This is the only reason the demo is laptop-only.

Verify the current state on any machine:

```powershell
docker manifest inspect ghcr.io/msf4-0/comp-demo-bench:v16   # 401 = private
docker pull ghcr.io/msf4-0/comp-demo-bench:v16               # unauthorized = private
```

---

## 2. Acceptance criteria for "ready for everyone"

The demo is distributable only when all of these hold. Criteria 1–6 are the
release gate; 7–8 are quality gates.

| # | Criterion | How it is proven |
|---|---|---|
| 1 | The bench image is **anonymously pullable** (no GitHub account, no PAT) | `docker logout ghcr.io; docker manifest inspect ghcr.io/msf4-0/comp-demo-bench:v16` returns a manifest |
| 2 | `start.ps1` **tries the pull first** on a machine without the image, and only builds as a fallback | run on a clean machine/Docker; log shows `bench image pulled in N min` |
| 3 | A failed pull prints the exact remediation link instead of silently building | stop GHCR access; run `start.ps1`; expect the three `WARN` lines |
| 4 | Cold start ≤ **15 min** on a 20 Mbit/s link (pull + 5–6 min seed + wiring) | time `start.ps1` from a clean Docker state |
| 5 | No secrets and no machine-specific paths are needed for the local demo | fresh clone has no `.env`; `start.ps1` creates it from `.env.example`; `ci.yml` hygiene job passes |
| 6 | The published image matches `main` (apps import, templates non-empty) | `ci.yml` smoke job: `frappe, erpnext, barcode_shrdc, shopify, eu_einvoice, reportlab, qrcode, PIL, drafthorse, saxonche` all import |
| 7 | Every advertised feature is either working or explicitly reported | `setup.ps1 -VerifyOnly` prints a per-feature table; `up.ps1` exits non-zero on a missing advertised feature |
| 8 | The image platform is documented | currently **linux/amd64 only**; ARM hosts must use `--platform linux/amd64` (Docker Desktop emulation) |

Not part of the gate: Shopify, ngrok and the planner API tokens need per-machine
credentials. They are intentionally optional in `start.ps1 -SkipTunnel` and are
documented in README section 9.

### Machine prerequisites (put these in the invite)

- Docker Desktop with **≥ 8 GB RAM** and **≥ 20 GB free disk** (bench image 3 GB,
  MariaDB volume, Metabase 3 GB limit).
- Windows 10/11 + PowerShell 5.1, or Linux/macOS with Docker Compose v2.
- **linux/amd64** host or emulation: the published image is amd64 only, so Apple
  Silicon needs `--platform linux/amd64` (already passed by the pull scripts).
- A network that can reach `ghcr.io` (corporate TLS interception breaks pulls).

---

## 3. Go-live checklist (maintainer, ~2 minutes)

1. Open <https://github.com/msf4-0?tab=packages>.
2. Select **comp-demo-bench**.
3. **Package settings** → **Danger Zone** → **Change visibility** → **Public**.
   - If the dialog offers to link the package to the repository, link
     `erpnext-v16-integrations-demo`. Public visibility alone is enough.
4. From any machine that is **not** logged in to GHCR, run:

   ```powershell
   docker logout ghcr.io
   docker manifest inspect ghcr.io/msf4-0/comp-demo-bench:v16
   docker pull ghcr.io/msf4-0/comp-demo-bench:v16
   ```

   Expected: a manifest listing, then layers downloading. No `unauthorized`.

5. Run the whole path on a clean clone:

   ```powershell
   git clone https://github.com/msf4-0/erpnext-v16-integrations-demo.git
   cd erpnext-v16-integrations-demo
   powershell -ExecutionPolicy Bypass -File .\start.ps1
   ```

   Expected: `bench image pulled in …` (not `building`), seed exits 0, ERPNext
   answers on :8000, `READY` banner. Total wall clock ≤ 15 min.

That is the entire release. No code change is required to flip visibility; the
repository is already wired for the pull path.

**Why this cannot be automated from the repo:** `msf4-0` is an *organization*, and
changing an org package's visibility needs a classic PAT with `write:packages`
that belongs to an **org owner**. The Actions `GITHUB_TOKEN` cannot administer
org packages, and the token available on this machine is an account that has
repo admin but no package scope — `/orgs/msf4-0/packages/container/comp-demo-bench`
answers `403`. Do not put such a PAT in the repo; use the UI once.

---

## 4. What the repo does today (already done)

- `.github/workflows/publish-image.yml` — builds on `v*` tags or manual dispatch,
  pushes `:v16` plus the immutable tag, uses GHA layer cache.
- `.github/workflows/ci.yml` — hygiene (clean checkout, no machine paths, every
  app has a non-empty `hooks.py`), compose/PowerShell/Python validation, bench
  image build + push on `main`, and an import smoke test of the pushed image.
- `start.ps1` — pulls the GHCR image by default, tags it as the local
  `comp_demo-bench:v16`, and only builds when the pull fails (`-NoPull` to skip).
- `pull-bench.ps1` — the same pull step for the other entry point; `up.ps1`
  (used by `setup.ps1 -Full`) calls it before `docker compose create`, so the
  documented `setup.ps1` route also avoids the build.
- `docker-compose.yml` — `image: ${BENCH_IMAGE:-comp_demo-bench:v16}` with the
  `build:` fallback kept for offline work.
- `docs/DISTRIBUTION.md` (this file) — the contract above.

## 5. If the package must stay private

Then "everyone" means "people with a GitHub account that has `read:packages` on
the package". In that case:

```powershell
# each colleague, once
echo <PAT with read:packages> | docker login ghcr.io -u <github-user> --password-stdin
powershell -ExecutionPolicy Bypass -File .\start.ps1
```

Document that PAT flow instead of the anonymous one, and add the login step to
the onboarding README. Anonymous public visibility is strictly simpler.
