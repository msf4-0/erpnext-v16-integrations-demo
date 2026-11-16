# Bench image policy (tags, digests, platforms, size)

The 3 GB bench image is the only slow part of the demo. This file defines how it
is named, pinned, measured and published so two colleagues can prove they run
the same thing.

## Tags

| Tag | Moves? | Use |
|---|---|---|
| `ghcr.io/msf4-0/comp-demo-bench:v16` | yes | default; what `start.ps1` / `start.sh` pull |
| `ghcr.io/msf4-0/comp-demo-bench:v16.3` | no | release tag, for pinning a known-good build |
| `ghcr.io/msf4-0/comp-demo-bench:<git-sha>` | no | every `main` build from `ci.yml` |
| `ghcr.io/msf4-0/comp-demo-bench@sha256:...` | no | the only fully reproducible reference |

`publish-image.yml` prints the digest to the job summary on every release. Copy
the `pin:` line from there.

## Pinning

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

## Platforms

- **linux/amd64** — default, tested by `e2e.yml` on every nightly run.
- **linux/arm64** — experimental. Run `publish-image` manually with
  `platforms=linux/amd64,linux/arm64`; the workflow adds QEMU and publishes a
  multi-arch manifest under the same tags. Verify `docker manifest inspect`
  lists both before advertising it.
- Apple Silicon without an arm64 image: Docker Desktop runs the amd64 image under
  emulation. It works but is slow; `start.sh`/`start.ps1` already pass
  `--platform linux/amd64`.

## Size budget

| Measure | Value |
|---|---|
| Local uncompressed image | ~3.0 GB (13 days after build, `docker image ls`) |
| Compressed (registry) | measured per release by `scripts/image-size.sh` |
| Budget | **3.0 GB compressed** (warning, see below) |

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

## What CI guarantees

| Workflow | Guarantee |
|---|---|
| `ci.yml` | the image builds from `main`; pushed by digest; apps import |
| `publish-image.yml` | tagged release is pushed, digest recorded, size measured, anonymous pull checked |
| `e2e.yml` | the published image seeds, starts, answers ping, accepts a login, serves a seeded DocType |
| `make-package-public.yml` | visibility can be flipped with an org-owner PAT, then re-verified anonymously |

## Related

- `docs/DISTRIBUTION.md` — the release gate and go-live checklist
- `bake/bench.Dockerfile` — what goes into the image
