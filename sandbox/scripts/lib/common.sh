#!/usr/bin/env bash
# Shared helpers for provision-base.sh and install-app.sh.
# Sourced, not run directly.

set -uo pipefail

BENCH_DIR="/home/frappe/frappe-bench"
SITE_NAME="${SITE_NAME:-frontend}"

log() { echo "[common] $*" >&2; }

# --- Fail-fast guard: verify the base container/DB actually match what
#     this ERPNext version needs, BEFORE bench init/new-site run. The goal
#     is a clear early error instead of a confusing mid-way failure. ---

# 1) Python: legacy versions need a specific interpreter. The image sets
#    PYTHON_VERSION_V<N>; if set, the named pyenv python MUST exist and
#    must actually report that version. A silent fallback to the image's
#    default python is exactly what broke v12 before (default was 3.10,
#    v12 needs 3.7) — so fail loudly instead of silently proceeding.
# 2) DB charset: v12 and older require utf8mb4/utf8mb4_unicode_ci. The
#    compose db service must be started with the utf8mb4 charset args,
#    otherwise new-site dies on the DB config check ("Expected value
#    utf8mb4, found latin1"). Check the live server's @@character_set_server
#    before attempting a site.
check_base_requirements() {
  local version="$1"
  local ok=1

  local py_var="PYTHON_VERSION_V$version"
  if [ -n "${!py_var:-}" ]; then
    local want="${!py_var}"
    local exec="/home/frappe/.pyenv/versions/$want/bin/python"
    if [ ! -x "$exec" ]; then
      log "ERROR: $py_var=$want but $exec is missing."
      log "  The image changed under us — cannot build v$version."
      ok=0
    else
      local got
      got=$("$exec" --version 2>&1 | awk '{print $2}')
      if [ "$got" != "$want" ]; then
        log "ERROR: $exec reports Python $got, expected $want (per $py_var)."
        ok=0
      else
        log "python check OK: $exec -> $got"
      fi
    fi
  else
    # No explicit pin. Verify the default python is new enough to import the
    # modern `collections.abc` (breaks on <=3.9) OR old enough to still have
    # `collections.MutableMapping` (removed in 3.10). Best-effort: just warn.
    log "note: $py_var not set; using image default python (cannot pre-verify)"
  fi

  # DB charset check via the venv's pymysql (root credentials come from the
  # compose/DB_ROOT_PASSWORD values; default is 'admin').
  if "$BENCH_DIR/env/bin/python" -c 'import pymysql' 2>/dev/null; then
    local cs
    cs=$("$BENCH_DIR/env/bin/python" - <<'PYEOF' 2>/dev/null
import os, pymysql
try:
    c = pymysql.connect(host="db", port=3306, user="root",
                        password=os.environ.get("DB_ROOT_PASSWORD", "admin"))
    with c.cursor() as cur:
        cur.execute("SELECT @@character_set_server, @@collation_server")
        row = cur.fetchone()
    print("%s|%s" % (row[0], row[1]))
except Exception as e:
    print("ERROR|%s" % e)
PYEOF
)
    local cs_charset="${cs%%|*}" cs_collation="${cs##*|}"
    if [ "$cs_charset" = "ERROR" ]; then
      log "DB charset check could not connect (is the db service up?): $cs_collation"
      log "  Will let new-site surface a DB error rather than false-fail here."
    elif [ "$cs_charset" != "utf8mb4" ] || [ "$cs_collation" != "utf8mb4_unicode_ci" ]; then
      log "ERROR: DB server charset is $cs_charset/$cs_collation, v$version needs utf8mb4/utf8mb4_unicode_ci."
      log "  Start the db service with:"
      log "    command: [--character-set-server=utf8mb4, --collation-server=utf8mb4_unicode_ci]"
      ok=0
    else
      log "DB charset check OK: $cs_charset/$cs_collation"
    fi
  else
    log "note: pymysql unavailable in venv, skipping live DB charset check"
  fi

  [ "$ok" -eq 0 ] && return 1
  return 0
}

# --- Detection helpers: replace the [ASSUMPTION]-flagged hardcoded values
#     from the lessons-learned doc with runtime checks. ---

# Find the real site-packages dir inside the bench venv instead of
# assuming a specific Python version (e.g. hardcoding python3.14, which
# will silently break if the base image updates).
detect_site_packages() {
  local found
  found=$(find "$BENCH_DIR/env/lib" -maxdepth 2 -type d -name 'site-packages' 2>/dev/null | head -n1)
  if [ -z "$found" ]; then
    log "ERROR: could not detect site-packages dir under $BENCH_DIR/env/lib"
    return 1
  fi
  echo "$found"
}

# Only install redis-server if it's actually missing — the base image
# lacking it was true at time of testing, but is not guaranteed to stay
# true if :latest moves.
ensure_redis_server() {
  if command -v redis-server >/dev/null 2>&1; then
    log "redis-server already present, skipping install"
    return 0
  fi
  log "redis-server not found — installing (requires root)"
  apt-get update -qq
  # Debian security repos routinely prune superseded point releases, so the
  # version apt prefers can 404 ("Failed to fetch ... redis-server_6.0.16-1
  # +deb11u9 ... 404 Not Found") while an older version is still served from
  # the main repo. Try the plain install, then fall back to pinning the
  # newest version apt-cache actually still lists (madison output col 2).
  if ! apt-get install -y -qq redis-server; then
    log "plain install failed (likely a pruned security-repo version) — pinning an available version"
    local ver
    ver=$(apt-cache madison redis-server | awk 'NR==1 {print $3}')
    if [ -n "$ver" ]; then
      log "installing redis-server=$ver (and matching redis-tools)"
      apt-get install -y -qq "redis-server=$ver" "redis-tools=$ver" \
        || apt-get install -y -qq --fix-missing redis-server
    else
      log "ERROR: no redis-server candidate found via apt-cache madison"
      return 1
    fi
  fi
  command -v redis-server >/dev/null 2>&1
}

# The DB name is a random hash, not the site name — read it from
# site_config.json rather than assuming.
get_db_name() {
  local site="$1"
  python3 -c "import json; print(json.load(open('$BENCH_DIR/sites/$site/site_config.json'))['db_name'])"
}

# Locate hooks.py under apps/<app> and derive the .pth target as its
# parent's parent. Works for both flat (apps/<app>/<pkg>/hooks.py) and
# nested (apps/<app>/<pkg>/<pkg>/hooks.py) layouts without needing to
# know which one in advance.
detect_pth_target() {
  local app="$1"
  local hooks_path
  hooks_path=$(find "$BENCH_DIR/apps/$app" -maxdepth 3 -name 'hooks.py' 2>/dev/null | head -n1)
  if [ -z "$hooks_path" ]; then
    log "ERROR: no hooks.py found under apps/$app"
    return 1
  fi
  dirname "$(dirname "$hooks_path")"
}

# Find one doctype name from the app to use for REST verification, so
# recipes only need to declare verify_doctype when overriding this guess.
detect_verify_doctype() {
  local app="$1"
  local doctype_json
  doctype_json=$(find "$BENCH_DIR/apps/$app" -path '*/doctype/*/*.json' 2>/dev/null | head -n1)
  [ -z "$doctype_json" ] && return 1
  python3 -c "import json; print(json.load(open('$doctype_json'))['name'])" 2>/dev/null
}

# 'Custom Script' was renamed to 'Client Script' in v15 (not v16 — the
# v15 base image has no frappe.core.doctype.custom_script module; the
# original v16 gate silently skipped the fixture on v15). The
# fixture transformation is mechanical and safe: rename custom_script.json
# -> client_script.json, flip each entry's "doctype" to "Client Script",
# and update hooks.py's fixtures list. Auto-convert on v15+ so install-app
# doesn't die on the missing `tabCustom Script` table.
check_custom_script_fixture() {
  local app="$1" version="$2"
  local appdir="$BENCH_DIR/apps/$app"
  if [ "$version" -ge 15 ] 2>/dev/null && grep -rq "Custom Script" "$appdir" 2>/dev/null; then
    log "v$version: converting 'Custom Script' fixtures to 'Client Script'"
    local fixture
    fixture=$(find "$appdir" -name 'custom_script.json' 2>/dev/null | head -n1)
    if [ -n "$fixture" ]; then
      python3 - "$fixture" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for x in d:
    x["doctype"] = "Client Script"
json.dump(d, open(p, "w"), indent=1)
PYEOF
      mv "$fixture" "$(dirname "$fixture")/client_script.json"
    fi
    # Update hooks.py fixtures list (and any other stray references).
    grep -rl "Custom Script" "$appdir" 2>/dev/null | while read -r f; do
      sed -i 's/Custom Script/Client Script/g' "$f"
    done
    log "  converted. Re-run install-app/migrate to sync the renamed fixture."
    return 0
  fi
  return 0
}

# Apps often ship stale/borrowed custom_field.json entries (e.g. a stray
# 'Frepple Item Distribution' button left from a different app). When such a
# record's target DocType isn't installed, frappe ABORTS syncing the rest of
# the file from that record onward — the records after it silently never
# sync. This is not limited to legacy versions: observed on v16 with
# barcode_shrdc (the Frepple record at index 15 left the 5 barcode fields
# after it missing, breaking the app's client scripts). Prune those entries
# out of custom_field.json (in place) before install so the real fixtures
# sync, on every version. Dropping a field whose DocType doesn't exist loses
# nothing — it could never sync anyway.
filter_missing_custom_field_dts() {
  local app="$1" version="$2"
  local f
  f=$(find "$BENCH_DIR/apps/$app" -path '*/fixtures/custom_field.json' 2>/dev/null | head -n1)
  [ -z "$f" ] && return 0
  # Query the DB via the venv's pymysql and the site's own config, NOT via
  # frappe.init/connect: a raw frappe connect needs a full bench context and
  # dies with FileNotFoundError '/home/frappe/logs/database.log' when run
  # outside it (docs/WINDOWS-QUOTING.md rule 7). We only need to know which
  # DocTypes exist, so a direct information_schema query is sufficient and
  # has no such dependency.
  "$BENCH_DIR/env/bin/python" - "$f" <<'PYEOF'
import json, os, sys, pymysql

fixture = sys.argv[1]
bench = "/home/frappe/frappe-bench"
site = os.environ.get("SITE_NAME", "frontend")
common = json.load(open(os.path.join(bench, "sites", "common_site_config.json")))
sitecf = json.load(open(os.path.join(bench, "sites", site, "site_config.json")))

conn = pymysql.connect(
    host=common.get("db_host", "db"),
    port=int(common.get("db_port", 3306)),
    user=sitecf["db_user"],
    password=sitecf["db_password"],
    database=sitecf["db_name"],
)
with conn.cursor() as cur:
    cur.execute("SELECT name FROM `tabDocType`")
    existing = {r[0] for r in cur.fetchall()}
conn.close()

data = json.load(open(fixture))
kept, dropped = [], []
for x in data:
    if x.get("doctype") != "Custom Field":
        kept.append(x)
        continue
    dt = x.get("dt")
    if dt and dt in existing:
        kept.append(x)
    else:
        dropped.append(x.get("name") or dt)

if dropped:
    print("[common] dropped %d custom_field fixture(s) referencing missing doctypes:" % len(dropped))
    for d in dropped:
        print("[common]   - %s" % d)
    json.dump(kept, open(fixture, "w"), indent=1)
else:
    print("[common] custom_field fixtures: all target doctypes exist, nothing dropped")
PYEOF
}

# --- Place a LOCAL app directory at apps/<app> without the "nested tree"
#     trap. ---
#
# Why this exists: `docker compose cp` writes files into the container as
# ROOT. The old inline logic (`rm -rf apps/$APP; cp -r "$REPO" apps/$APP`)
# then ran as the `frappe` user, could not delete root-owned files, ignored
# the failure, and `cp -r` NESTED the tree as apps/<app>/<app>/... . The
# nested hooks.py was then picked up by detect_pth_target, producing a wrong
# .pth and a broken app (found while installing amazon_integration, entry
# #48). This helper makes the operation self-healing and verifiable:
#   1. remove any existing apps/<app> using sudo when plain rm can't (root-owned)
#   2. copy with `cp -a "$REPO/." apps/<app>/` so it MERGES into a fresh dir
#      rather than nesting
#   3. drop .git, chown the result to the current user
#   4. assert exactly ONE hooks.py and print the resolved .pth target
#
# $1 = app name, $2 = absolute path to the source directory.
# Returns non-zero with a clear message if the result is not exactly one app.
install_local_app_dir() {
  local app="$1" src="$2"
  local dest="$BENCH_DIR/apps/$app"

  if [ ! -d "$src" ]; then
    log "ERROR: local app source '$src' is not a directory"
    return 1
  fi

  # 1) clear the destination, escalating to sudo for root-owned leftovers
  if [ -e "$dest" ] && ! rm -rf "$dest" 2>/dev/null; then
    log "destination apps/$app had files we couldn't remove (root-owned —"
    log "a 'docker compose cp' artifact); removing with sudo"
    sudo rm -rf "$dest" || { log "ERROR: sudo rm failed for $dest"; return 1; }
  fi
  if [ -e "$dest" ]; then
    log "ERROR: apps/$app still exists after cleanup — refusing to copy"
    log "  (a copy onto an existing dir would NEST it; see entry #48)"
    return 1
  fi
  mkdir -p "$dest" || return 1

  # 2) merge the source INTO the fresh dir (trailing /. on a dir source)
  cp -a "$src/." "$dest/" || { log "ERROR: copy of $src failed"; return 1; }

  # 3) normalise ownership + drop any git metadata
  sudo chown -R "$(id -un):$(id -gn)" "$dest" 2>/dev/null || true
  rm -rf "$dest/.git"

  # 4) verify: exactly one hooks.py must exist
  local hooks_count hooks_path
  hooks_count=$(find "$dest" -maxdepth 3 -name hooks.py 2>/dev/null | wc -l | tr -d ' ')
  if [ "$hooks_count" != "1" ]; then
    log "ERROR: expected exactly 1 hooks.py under apps/$app, found $hooks_count"
    find "$dest" -maxdepth 3 -name hooks.py 2>/dev/null | sed 's/^/  /' >&2
    log "  Refusing to continue (the tree is likely nested)."
    return 1
  fi
  hooks_path=$(find "$dest" -maxdepth 3 -name hooks.py 2>/dev/null | head -n1)
  log "placed app at apps/$app (hooks.py: ${hooks_path#$BENCH_DIR/})"
  return 0
}

restart_bench_serve() {
  # The serve process runs as `frappe serve` (via `bench_helper frappe
  # serve`), NOT `bench serve` — a `pkill -f 'bench serve'` silently
  # misses it and leaves a stale process serving with an outdated .pth
  # (which then 500s on any app added after it started). Match both.
  pkill -f 'frappe serve' 2>/dev/null
  pkill -f 'bench serve' 2>/dev/null
  sleep 3
  # Must be DETACHED: a plain `( … &)` dies when the exec session ends, and
  # `nohup … &` without a stdin redirect can hold the exec pipe open so the
  # tool call appears to hang. `setsid nohup … < /dev/null & disown` is the
  # documented-good form (docs/WINDOWS-QUOTING.md rule 8).
  ( cd "$BENCH_DIR" && setsid nohup bench serve --port 8000 > /tmp/bench-serve.log 2>&1 < /dev/null & disown )
}

# Real timeout instead of an open-ended loop — a stuck DB-readiness loop
# was the exact failure mode that made an earlier install look "hung."
wait_for_site() {
  local timeout="${1:-120}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if curl -s -o /dev/null -H "Host: $SITE_NAME" "http://localhost:8000/api/method/ping"; then
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  log "ERROR: site did not respond within ${timeout}s"
  return 1
}
