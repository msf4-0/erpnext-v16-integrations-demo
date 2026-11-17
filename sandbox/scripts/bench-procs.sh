#!/usr/bin/env bash
# bench-procs.sh - which frappe background jobs are alive?
#
# WHY THIS EXISTS: the bench image has no procps (`ps: command not found`), so
# `bench ps` / `ps -eo args` returns nothing and setup.ps1 believed the
# scheduler and worker were missing on every run - starting a new pair each
# time, so workers accumulated. Reading /proc needs NUL-safe parsing, which is
# painful to inline through PowerShell -> docker exec -> bash -lc quoting, so it
# lives here as a file that is docker cp'd in.
#
# Prints one word per line: `worker` and/or `schedule`.

for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
    case "$cmd" in
        *"bench_helper frappe worker"*)   echo worker ;;
        *"bench_helper frappe schedule"*) echo schedule ;;
    esac
done
