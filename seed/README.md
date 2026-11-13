# Seed data

`frontend-database.sql.gz` is a `bench backup` of a fully built demo site
(company SHRDC, 60 items, 2 item barcodes, demo user, planner work orders).

It exists so that **`docker compose up` on a fresh clone produces a working site
instead of an empty one**. Without it, the bench container starts with an empty
`sites/` volume and answers:

```
404 localhost does not exist
```

which is the "it starts but nothing works" report.

## How it is used

The `seed` service in `docker-compose.yml` runs `seed-site.sh` once per boot:

| State | What happens | Cost |
|---|---|---|
| Site already exists | Logs `nothing to do`, exits 0 | ~2 s |
| No site, dump present | `bench new-site` + `bench restore` | ~5 min |
| No site, no dump | Exits 1 with instructions | instant |

`bench` declares `depends_on: seed: condition: service_completed_successfully`,
so it never starts against a half-restored volume.

## Refresh the dump

From a machine with a good running stack:

```powershell
docker exec comp_demo-bench-1 bash -lc "cd /home/frappe/frappe-bench && bench --site frontend backup"
# then copy the newest *-database.sql.gz out of
#   sites/frontend/private/backups/
# and commit it here as seed/frontend-database.sql.gz
```

Use `--with-files` only if documents/attachments matter; the demo's QR and
barcode PNGs are regenerated on demand, so the default (DB only, ~1.3 MB) is
enough and keeps the repo small.

## Notes

- The dump contains demo business data only. It carries **no** `.env` secrets;
  site credentials are re-created by `bench new-site` on restore.
- Backups are plain SQL gzip, so they are diffable in principle but binary in
  git. If this ever grows past a few MB, move it to a GitHub Release asset and
  change `seed-site.sh` to download it instead.
