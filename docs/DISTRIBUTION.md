# Distributing comp_demo, and the bench image policy

## Distributing comp_demo to other machines

The goal: a colleague clones the repo, runs one command, and has a working
demo in ~10 minutes — with **no local Docker build** and no knowledge of this
machine.

This document is the acceptance contract for that goal. It also records what is
already true, what is blocked, and the exact steps to finish.

---

### 1. The one slow step, and why it is slow

`bake/bench.Dockerfile` produces a **3 GB** image (0.98 GB compressed on the wire) containing Frappe, ERPNext v16
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

### 2. Acceptance criteria for "ready for everyone"

The demo is distributable only when all of these hold. Criteria 1–6 are the
release gate; 7–8 are quality gates.

| # | Criterion | How it is proven |
|---|---|---|
| 1 | The bench image is retrievable **anonymously** (no GitHub account, no PAT) - either the GHCR pull or the public release bundle | `docker logout ghcr.io; docker manifest inspect …` returns a manifest, **or** the release asset downloads |
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

#### Machine prerequisites (put these in the invite)

- Docker Desktop with **≥ 8 GB RAM** and **≥ 20 GB free disk** (bench image 3 GB,
  MariaDB volume, Metabase 3 GB limit).
- Windows 10/11 + PowerShell 5.1, or Linux/macOS with Docker Compose v2.
- **linux/amd64** host or emulation: the published image is amd64 only, so Apple
  Silicon needs `--platform linux/amd64` (already passed by the pull scripts).
- A network that can reach `ghcr.io` (corporate TLS interception breaks pulls).

---

### 3. Go-live checklist (maintainer, ~2 minutes)

1. Open <https://github.com/organizations/msf4-0/settings/packages>.
   **Organization settings -> Packages**: allow public package visibility.
   Verified 2026-11-16: the package dialog greys out **Public** with
   "Setting is disabled by organization administrators", so the per-package
   step cannot succeed until this org policy is changed. Only an organization
   owner can do it.
2. Open <https://github.com/msf4-0?tab=packages>.
3. Select **comp-demo-bench**.
4. **Package settings** -> **Danger Zone** -> **Change visibility** -> **Public**.
   - If the dialog offers to link the package to the repository, link
     `erpnext-v16-integrations-demo`. Public visibility alone is enough.
5. From any machine that is **not** logged in to GHCR, run:

   ```powershell
   docker logout ghcr.io
   docker manifest inspect ghcr.io/msf4-0/comp-demo-bench:v16
   docker pull ghcr.io/msf4-0/comp-demo-bench:v16
   ```

   Expected: a manifest listing, then layers downloading. No `unauthorized`.

6. Run the whole path on a clean clone:

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

### 4. What the repo does today (already done)

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

### 5. If the package stays private: the release bundle (works today)

The org currently disables public packages, so the GHCR pull needs a token. The
**public fallback does not**: `release-bundle.yml` exports the same image as a
GitHub Release asset with a stable name, and the scripts try it automatically.

| Item | Value |
|---|---|
| Asset | `releases/latest/download/comp-demo-bench-v16-amd64.tar.gz` |
| Size | **932 MB** (977,010,886 bytes) - verified 2026-11-16 |
| Checksum | same URL + `.sha256` |
| Auth | none - public repo release asset (anonymous HTTP 200 confirmed) |

Manual path:

```bash
curl -fL -O https://github.com/msf4-0/erpnext-v16-integrations-demo/releases/latest/download/comp-demo-bench-v16-amd64.tar.gz
curl -fL -O https://github.com/msf4-0/erpnext-v16-integrations-demo/releases/latest/download/comp-demo-bench-v16-amd64.tar.gz.sha256
sha256sum -c comp-demo-bench-v16-amd64.tar.gz.sha256
docker load -i comp-demo-bench-v16-amd64.tar.gz
```

`pull-bench.ps1` / `start.sh` do exactly this when the GHCR pull fails, verify
the checksum, `docker load`, and retag as `comp_demo-bench:v16`. Override the
location with `BENCH_BUNDLE_URL` (env or `.env`) for a fork or an internal
mirror.

Limits: a release asset is not a registry - no per-layer caching, no digest
reference, no multi-arch manifest. It exists so a colleague with no GitHub
account can still run the demo; GHCR stays the primary path.

If you would rather hand out tokens than use the bundle: each colleague runs
`echo <PAT with read:packages> | docker login ghcr.io -u <user> --password-stdin`
once, then `start.ps1` pulls normally.

## Bench image policy (tags, digests, platforms, size)

The 3 GB bench image is the only slow part of the demo. This file defines how it
is named, pinned, measured and published so two colleagues can prove they run
the same thing.

### Tags

| Tag | Moves? | Use |
|---|---|---|
| `ghcr.io/msf4-0/comp-demo-bench:v16` | yes | default; what `start.ps1` / `start.sh` pull |
| `ghcr.io/msf4-0/comp-demo-bench:v16.3` | no | release tag, for pinning a known-good build |
| `ghcr.io/msf4-0/comp-demo-bench:<git-sha>` | no | every `main` build from `ci.yml` |
| `ghcr.io/msf4-0/comp-demo-bench@sha256:...` | no | the only fully reproducible reference |

`publish-image.yml` prints the digest to the job summary on every release. Copy
the `pin:` line from there.

### Pinning

Default (moving tag) — always the newest published build:

```dotenv
# .env
# BENCH_IMAGE is optional; leave it unset to use comp_demo-bench:v16 locally.
```

Reproducible (digest) — the same bytes for everyone, forever:

```dotenv
# .env
BENCH_IMAGE=ghcr.io/msf4-0/comp-demo-bench@sha256:<digest>
```

`start.ps1` / `start.sh` treat a namespaced `BENCH_IMAGE` as the pull target and
still tag it locally as `comp_demo-bench:v16`, so compose does not build.

Check what a machine is actually running:

```powershell
docker image inspect --format '{{index .RepoDigests 0}}' comp_demo-bench:v16
```

### Platforms

- **linux/amd64** — default, tested by `e2e.yml` on every nightly run.
- **linux/arm64** — experimental. Run `publish-image` manually with
  `platforms=linux/amd64,linux/arm64`; the workflow adds QEMU and publishes a
  multi-arch manifest under the same tags. Verify `docker manifest inspect`
  lists both before advertising it.
- Apple Silicon without an arm64 image: Docker Desktop runs the amd64 image under
  emulation. It works but is slow; `start.sh`/`start.ps1` already pass
  `--platform linux/amd64`.

### Size budget

| Measure | Value |
|---|---|
| Local uncompressed image | ~3.0 GB (`docker image ls`) |
| Compressed (registry) | **0.98 GB** - measured 2026-11-16 on `:main`, run `43823831734`, 25 layers |
| Budget | **3.0 GB compressed** (warning, see below) |

Over the wire a colleague downloads ~1 GB, not 3 GB: the 3 GB figure is the
unpacked local image. That is why a pull takes minutes, not an hour.

`publish-image.yml` runs `scripts/image-size.sh <ref> 3000000000`, which sums the
compressed layer sizes for `linux/amd64` and prints them in the job log. It is a
**warning, not a gate** until a baseline has been reviewed across a few releases:
the budget number needs evidence, not a guess. Once the measured values are
stable, remove `continue-on-error` to make it a hard gate.

Measure locally (needs registry access):

```bash
./scripts/image-size.sh ghcr.io/msf4-0/comp-demo-bench:v16 3000000000
```

Ideas if it grows: build-only deps out of the final layer, `pip --no-cache-dir`,
prune `node_modules` after `bench build`, drop unused ERPNext locales.

### What CI guarantees

| Workflow | Guarantee |
|---|---|
| `ci.yml` | the image builds from `main`; pushed by digest; apps import |
| `publish-image.yml` | tagged release is pushed, digest recorded, size measured, anonymous pull checked |
| `e2e.yml` | the published image seeds, starts, answers ping, accepts a login, serves a seeded DocType |
| `make-package-public.yml` | visibility can be flipped with an org-owner PAT, then re-verified anonymously |

### Related

- `docs/DISTRIBUTION.md` — the release gate and go-live checklist
- `bake/bench.Dockerfile` — what goes into the image
