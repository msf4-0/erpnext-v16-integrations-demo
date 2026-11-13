# Baking comp_demo into proper container images

> Authoritative current architecture and database durability:
> [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md). The tmpfs references
> below are historical and describe an earlier configuration.

The current setup keeps three things OUT of a durable image:

| What | Where today | Lost on… |
| --- | --- | --- |
| frappe + erpnext + apps + venv + render deps | bench container **writable layer** (installed at runtime by `up.ps1`) | `docker compose down` + recreate |
| site DB (900 tables) | `db_data` named volume mounted at `/var/lib/mysql` | explicit volume deletion or storage loss |
| staged scripts/repos | `/tmp/...` in the container | every run |

The database and site files use separate named volumes (`db_data` and
`bench_sites`). The remaining sections describe the image-baking history and
options; the database strategy in use is Track 2b.

## Fresh clone — the default path

`docker-compose.yml` now carries a `build:` block on the `bench` service, so a
fresh `git clone` reproduces the exact `comp_demo-bench:v16` image straight from
`bake/bench.Dockerfile` — no `up.ps1` needed:

```powershell
git clone https://github.com/msf4-0/erpnext-v16-integrations-demo.git
cd erpnext-v16-integrations-demo
copy .env.example .env        # fill in Shopify / DB secrets
docker compose build bench    # builds comp_demo-bench:v16 from bake/bench.Dockerfile
docker compose up -d          # starts bench, db, redis, node-red, scheduler
```

> The image bakes the **code** (frappe + erpnext v16 + barcode_shrdc + shopify +
> eu_einvoice + render deps). It does **not** bake the live site **data** (the DB)
> — a fresh clone starts with an empty site. See Track 2 for making the data
> portable. Secrets stay in `.env` (gitignored); the image never embeds them.

## Track 1 — bake the CODE (safe, high value)

`bench.Dockerfile` builds `comp_demo-bench:v16` with everything installed at
build time. `up.ps1` then skips provision + app-install (steps 5–7) and only
creates/start the stack, dropping a full build from ~25–35 min to ~1–2 min.

```powershell
docker build -f bake/bench.Dockerfile -t comp_demo-bench:v16 .
```

Then point `docker-compose.yml` `bench.image:` at `comp_demo-bench:v16`.

## Track 2 — bake the DATA/DB (harder; pick a strategy)

An earlier setup used tmpfs because this host's container-storage write path was
measured to be pathological for MariaDB (in-container fsync ~600–900 ms; a
named volume took >300 s for 100 CREATE TABLEs). The current setup uses the
`db_data` named volume; initial population pays the write cost. The following
options record the historical trade-offs:

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
