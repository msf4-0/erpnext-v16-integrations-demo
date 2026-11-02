# Baking comp_demo into proper container images

The current setup keeps three things OUT of a durable image:

| What | Where today | Lost on… |
| --- | --- | --- |
| frappe + erpnext + apps + venv + render deps | bench container **writable layer** (installed at runtime by `up.ps1`) | `docker compose down` + recreate |
| site DB (900 tables) | `db` container **tmpfs** (`/var/lib/mysql`) | any stop / Docker restart |
| staged scripts/repos | `/tmp/...` in the container | every run |

Only `bench_sites` (the site files, NOT the DB) is a named volume. The goal is
to move all of the above into images built ahead of time.

## Track 1 — bake the CODE (safe, high value)

`bench.Dockerfile` builds `comp_demo-bench:v16` with everything installed at
build time. `up.ps1` then skips provision + app-install (steps 5–7) and only
creates/start the stack, dropping a full build from ~25–35 min to ~1–2 min.

```powershell
docker build -f bake/bench.Dockerfile -t comp_demo-bench:v16 .
```

Then point `docker-compose.yml` `bench.image:` at `comp_demo-bench:v16`.

## Track 2 — bake the DATA/DB (harder; pick a strategy)

The DB is tmpfs because this host's container-storage write path is pathological
for MariaDB (in-container fsync ~600–900 ms; a named volume took >300 s for 100
CREATE TABLEs). Baking does NOT remove that. Two options, each a trade-off:

### 2a — snapshot → tmpfs (fast boot, still ephemeral)
Bake a **tarball of the already-provisioned datadir** into the image, extract to
`/var/lib/mysql` on first boot. Raw file copy to RAM avoids the ~900-table DDL,
so boot is seconds–minutes. But a stop still discards changes.

### 2b — snapshot → named volume (durable, slow first populate)
Same tarball, but extract to a bind-mounted/named volume. Survives restarts. The
one-time populate pays the slow-write cost; after that the demo's incremental
writes are small. Requires re-testing the host write-latency claim (it may have
been Docker Desktop's WSL2 backend / antivirus scanning, fixable by a bind mount
to a non-scanned NTFS path).

## Issues to be aware of (bake is not a free lunch)

1. **Secrets leak into layers.** Admin password, ERPNext API token, Shopify
   tokens, `site_config.json`, and Node-RED `flows.json` get baked into image
   history — extractable by anyone with the image. Externalize them (env vars /
   mounted secrets) or accept the leak. See `.gitignore`, which already treats
   `flows.json` + `*.bak` as secret-bearing.
2. **Image size.** A full bake lands ~6–8 GB+; rebuilds are expensive, and this
   host already holds 148 GB (`a4h-snap`) + 85 GB SAP + 30 GB SAP images.
3. **Iteration cost.** The repo has ~100 `fix-*.sh` / `verify-*.sh` scripts, i.e.
   frequent app changes → a multi-GB rebuild per change. Use multi-stage: a
   stable base image + a thin, rebuildable site snapshot.
4. **DB durability vs latency is the real unresolved trade-off** — baking the
   data does not fix the host write path; it only pre-pays the DDL.
5. **ngrok + webhooks are inherently host/runtime** (dynamic public URL, free-plan
   single session) and can never be baked into the image.
6. **Keep the `compose up` workaround** (`create` + `docker start`) — `up` hangs
   on this host regardless of the image change.
7. **Pin tags** (`frappe/erpnext:v16.35.0`, not `:latest`) or the bake is not
   reproducible.
