# Tests

## verify-clean-clone.ps1

The onboarding gate. It clones **from GitHub** into `%TEMP%\comp_demo_clone_test`,
runs as its own compose project (`comp_demo_verify`, ports 8100/3101/1881/3006,
its own volumes), seeds the demo database, asserts the features, then tears
everything down. Your `comp_demo` stack is never referenced.

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\verify-clean-clone.ps1
powershell -ExecutionPolicy Bypass -File .\tests\verify-clean-clone.ps1 -Keep   # inspect afterwards
```

Checks:

| Step | Asserts |
|---|---|
| 0-1 | clone succeeds; `.env.example` boots after only port/project edits |
| 2-3 | compose create; db healthy; seeder exits 0 (it fails if the restore is empty) |
| 5-6 | `/api/method/ping` 200; desk, both barcode scripts and the item-tracking script return 200 |
| 7 | barcode_shrdc, shopify, eu_einvoice, item_tracking installed; planner health |

Run it before tagging a release, and after any change to `docker-compose.yml`,
`seed/`, or the `bench` startup block. It takes ~9 minutes because it exercises
the real first-run path; the CI jobs cover the static side in ~4.

Requires: Docker Desktop running, the `comp_demo-bench:v16` image present
locally (or reachable via `BENCH_IMAGE`), and GitHub reachable.