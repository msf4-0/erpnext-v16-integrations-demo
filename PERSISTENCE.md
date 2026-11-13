# Why app features disappeared after a restart — and the permanent fix

> Authoritative stack architecture, ports, versions, and database durability:
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Root cause

The `bench` container persisted **only** `/home/frappe/frappe-bench/sites` (the
`bench_sites` named volume). Everything else — `apps/item_tracking`,
`apps/metabase_integration`, their `*.pth` entries in
`env/lib/python3.14/site-packages`, and the `/assets/<app>` symlinks — lived in
the container's writable layer.

`docker compose up` / an image rebuild **recreates** that layer. The result:

* `apps/item_tracking` reverted to whatever was baked in the image (or vanished),
  so the Shift+I camera scanner and the custom pages disappeared.
* `apps/metabase_integration` vanished entirely while `sites/apps.txt`,
  `sites/frontend/site_config.json` (both on the volume) still listed it →
  `ModuleNotFoundError: No module named 'metabase_integration'` → the whole site
  returned HTTP 500.
* `/assets/item_tracking/...` 404'd because the alias symlink was gone, so the
  Desk JS was never loaded even when the file existed.

## Fix (all in `docker-compose.yml`)

1. **Bind-mount the app sources** so they are host files, not image files:

   ```yaml
   - ./repos/item_tracking:/home/frappe/frappe-bench/apps/item_tracking
   - ./repos/metabase_integration:/home/frappe/frappe-bench/apps/metabase_integration
   ```

2. **Re-create `*.pth` on every start.** The startup command loops over
   `apps/*/` and writes `env/lib/python*/site-packages/<app>.pth`. Without it
   `bench` cannot import bind-mounted apps.

3. **Re-create `/assets/<app>` aliases on every start.** The startup command
   links `assets/<app> -> ../apps/<app>/<app>/public`. Without it every static
   asset URL 404s.

4. `metabase_integration` was re-scaffolded as a minimal app (hooks/modules) so
   the existing DB DocTypes (`Metabase Settings`, `Metabase Dashboard`) load
   again. Its original controller/JS code was container-only and is gone; restore
   it from source control if it is needed.

## Barcode / QR rendering (`reportlab` 5.1)

`reportlab` 5.1 removed the bundled `_renderPM` C extension. `Drawing.asString("png")`
now needs `rlPyCairo` + `pycairo`, which are not installed and cannot be built
here (no cp314 wheel; no cairo headers/compiler in the image). `pycairo` was
previously present only in the container's writable layer, so barcode endpoints
started failing with `RenderPMError: cannot import desired renderPM backend`
after a recreate.

`item_tracking/.../tracked_item/raster.py` now tries PNG and falls back to
**SVG** (rendered pure-Python by reportlab). Both work in `<img>`, the Desk and
wkhtmltopdf print output. QR keeps using Pillow (`qrcode`), which is installed.

* Tracked Item endpoints `get_tracking_barcode_image` / `get_tracking_qr_image`
  therefore work without native dependencies.
* `barcode_shrdc`'s direct `get_barcode_image` (Barcode Printing labels/print
  formats) still needs `rlPyCairo`; the Tracked Item path catches that failure
  and uses the fallback.

## Verify after any restart

```powershell
curl.exe -s -o NUL -w "%{http_code}`n" http://localhost:8000/login
curl.exe -s http://localhost:8000/assets/item_tracking/js/item_tracking_scan.js | Select-String "shift+i"
docker exec comp_demo-bench-1 bench --site frontend list-apps
```

Expected: `200`, a match for `shift+i`, and both `item_tracking` and
`metabase_integration` listed.

## barcode_shrdc (Get Items Barcode / serial numbers)

The image ships an old `barcode_shrdc` (22 KB `barcode_printing.py`, 11.8 KB JS) that
has no `get_serial_summary` / `ensure_serials`, while the source repo has the
complete flow (36 KB py, 21 KB JS, commit `e89d712`). The mounted repo is now
authoritative, so the "existing serial or new serial" prompt has its backend and
survives restarts.
