# Windows / PowerShell -> `docker compose exec` quoting: rules for future runs

All sandbox commands run from a Windows PowerShell 5.1 host into a Linux
container via `docker compose -p erpnext-sandbox exec <svc> bash -lc "..."`.
That is 3-4 interpolation layers (PowerShell -> docker CLI -> bash -> the
Python/JSON/SQL/JS that bash then runs). Each layer mangles characters before
the next sees them. These rules were extracted from a run that hit every one
of them; follow them to avoid repeating the failures.

## Rules

1. **Never put multi-line or quote-heavy bash inline.** Write a SCRIPT file
   and run it. That is exactly what `provision-base.sh`, `install-app.sh`, and
   `ensure-root-prep.sh` exist for. Inline `bash -lc "..."` is only safe for a
   single simple command with no `$()`, no nested quotes, no backticks.

2. **Outer-quote with SINGLE quotes:** `bash -lc '...'`. Double quotes let
   PowerShell expand `$VAR`, `$(...)` and backticks *before* bash runs.

3. **Do NOT use `$(...)` or backticks in inline bash.** PowerShell eats them.
   - Symptom: ``unexpected EOF while looking for matching `)``
   - Backtick is PowerShell's escape char, so SQL like
     ``SELECT ... FROM `tabCustom Field` `` reaches the DB as `tabCustom`.
   - Fix: put the command in a script file, or base64 it (rule 5).

4. **Avoid `printf "\n"` inline** (the backslash gets stripped, so it appends a
   literal `n` -> `erpnextnbarcode_shrdc`). Use `echo >> file`, or a script
   file, or base64.

5. **For multi-line Python/SQL, BASE64 it** — the reliable escape hatch when
   everything else fails. It collapses all layers to one unbroken token:
   ```powershell
   $py = @'
   import frappe
   def run():
       print("hello from inside")
   '@
   $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($py))
   docker compose -p erpnext-sandbox exec bench bash -lc "echo $b64 | base64 -d > /tmp/x.py && cd /home/frappe/frappe-bench && env/bin/python /tmp/x.py"
   ```
   Same pattern for SQL (decode into a file, then `mariadb ... < file.sql`).

6. **Inside the container, use Linux tools** (`grep`, `sed`, `awk`, `tail`).
   PowerShell cmdlets (`Select-String`, `Get-*`) are host-only and fail with
   `bash: Select-String: command not found`.

7. **`bench execute` needs the target importable from an INSTALLED app
   package.** Put a `helper.py` inside `apps/<app>/<pkg>/` and call
   `<pkg>.<helper>.run`; a bare `/tmp/foo.py` or a module under `frappe/`
   fails with `App <name> is not installed` / `NameError`. Do **not** use raw
   `frappe.init()/connect()` scripts launched via `env/bin/python` — that dies
   with `FileNotFoundError: /home/frappe/logs/database.log` unless a full bench
   context exists. Go through `bench --site frontend execute <path>`.

8. **Backgrounding:** a `&`-ed process is killed when the exec session ends,
   and `nohup ... &` without `setsid`/stdin redirect can keep the exec pipe
   open so the tool call appears to hang. Use:
   ```
   setsid nohup <cmd> > /tmp/x.log 2>&1 < /dev/null & disown
   ```
   then verify in a **separate** exec (`curl` ping / `tail` the log).

9. **The db container's client is `mariadb`, not `mysql`.** The DB name is a
   random hash — read it from `sites/<site>/site_config.json`, don't guess it.

10. **`docker compose cp` does NOT overwrite existing files** (a nested
    `lib/common.sh` silently stayed stale). Copy each file individually, and
    `docker compose exec ... mkdir -p` the target dir first.
    - **Corollary — `cp <dir> <existing-dir>` NESTS, it does not merge.**
      `docker compose cp bench:/tmp/final-app/robotics_lab ./repos/robotics_lab`
      created `./repos/robotics_lab/robotics_lab/...` *inside* the existing
      directory, leaving a duplicated app tree (two `hooks.py`, two
      `device.json`). `detect_pth_target` picks `find ... -name hooks.py |
      head -n1`, so with duplicates the resolved `.pth` target depends on
      filesystem ordering — a latent break.
      **Always copy with the trailing `/.` to merge into the destination:**
      `docker compose cp bench:/tmp/final-app/robotics_lab/. ./repos/robotics_lab`
      and keep exactly ONE `hooks.py` in the tree. For a guaranteed-clean
      layout, tar it in the container and extract once on the host.

11. **Newer bench keeps only `sites/apps.txt`** (no root `apps.txt`). Any
    registration code must tolerate either (see `register_app_by_hand()` in
    `install-app.sh`).

## Quick self-check before running an inline command

If the command contains any of: `$`, `(`, `)`, backtick, `!`, a newline, or a
quote nested inside another quote of the same type -> it will likely break.
Move it into a script file or base64 payload.
