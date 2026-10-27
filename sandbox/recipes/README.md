# Recipes

A **recipe** is a small YAML file of app-specific facts that the generic
installer (`sandbox/scripts/install-app.sh`) can't derive on its own: a
non-default branch, extra pip/native dependencies, which doctype to verify
against, and notes explaining *why* (gotchas worth not rediscovering).

Looking for an app's **repo URL**? That lives in
[`../../APP-SOURCES.md`](../../APP-SOURCES.md), the known-app registry. A recipe
records *how to install* an app; `APP-SOURCES.md` records *where it comes from*.

The goal is the **fast path**: the next run finds your recipe, takes it, and
skips open-ended troubleshooting.

## Where recipes live and how they're found

1. **Your own recipes** go directly in this directory:
   `sandbox/recipes/<app_name>.yaml`
2. **Shipped examples** live in `sandbox/recipes/examples/`.

The installer looks in `sandbox/recipes/<app_name>.yaml` **first**, then
`sandbox/recipes/examples/<app_name>.yaml`. A recipe in this directory
overrides the matching example.

To install with a recipe, copy it into the container and pass its path:

```bash
docker compose -p erpnext-sandbox cp ./sandbox/recipes/<app>.yaml \
  bench:/tmp/recipes/<app>.yaml
docker compose -p erpnext-sandbox exec bench bash -lc \
  "/tmp/scripts/install-app.sh <app> <repo_url_or_local_dir> <version> /tmp/recipes/<app>.yaml"
```

## Format

See `_example.yaml` for an annotated template. The skeleton is:

```yaml
app: <app_name>
repo: <git url or ./repos/<dir>>     # a default source; the CLI arg wins

versions:
  "16":
    branch: <branch>                 # optional
    source: ./repos/<dir>            # optional; local dir instead of `repo`
    extra_pip: [pkg1, pkg2]          # optional
    verify_doctype: <DocType>        # optional; else auto-detected
    verified: true
    notes: |
      Why these values, and any gotchas (the reasoning matters).
```

## What NOT to put in a recipe

`install-app.sh` already handles these generically — declaring them is
redundant and can go stale:

- the `.pth` target (flat vs nested layout — auto-detected)
- which doctype to verify against (auto-detected; only pin it if the guess is
  wrong, e.g. a Single doctype)
- Single-doctype table recovery
- the `Custom Script` → `Client Script` fixture conversion (v15+)
- stale `custom_field.json` pruning (v14 and older)

If a fix would help **any** app on a version, it belongs in
`sandbox/scripts/lib/common.sh`, not a recipe. Only genuinely app-specific
residual facts belong here.

## Contributing an example

Examples in `examples/` are kept as working references — including the
hard-won gotchas. Point `repo:` at a public source (or document a local
`source:`), and keep personal paths out.
