<#
.SYNOPSIS
    Back up the comp_demo site to the host, before anything destructive.

.DESCRIPTION
    The site database lives on the `db_data` Docker volume, so a plain
    `docker compose down` keeps it. What does NOT survive is a volume removal
    (`down -v`, `-Wipe`, Docker Desktop "clean / reset") or a site recreate
    (`bench new-site --force`): the seeder then restores
    `seed/frontend-database.sql.gz`, which is a snapshot from the day it was
    committed. Anything created after that snapshot - BOMs, items, work orders -
    silently disappears.

    This script takes a real backup first, on the host, outside Docker:

      backups/<timestamp>/frontend-database.sql.gz
      backups/<timestamp>/frontend-site_config_backup.json
      backups/<timestamp>/MANIFEST.txt

    `setup.ps1 -Full`, `up.ps1 -Fresh` and `start.ps1` call it automatically
    before they touch anything destructive.

.PARAMETER RefreshSeed
    Also replace `seed/frontend-database.sql.gz` with this backup, so the next
    fresh clone gets current demo data. This changes a tracked file - commit it
    deliberately.

.PARAMETER Keep
    How many timestamped backups to keep on the host. Default 10.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup\backup

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup\backup -RefreshSeed
#>
param(
    [switch]$RefreshSeed,
    [int]$Keep = 10,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$EnvPath = Join-Path $Root '.env'
$BackupRoot = Join-Path $Root 'backups'

function Say([string]$m) { if (-not $Quiet) { Write-Host "  ...   $m" } }
function Ok([string]$m)  { Write-Host "  OK    $m" -ForegroundColor Green }
function Warn([string]$m){ Write-Host "  WARN  $m" -ForegroundColor Yellow }

if (-not (Test-Path $EnvPath)) { Warn 'no .env - nothing to back up'; exit 1 }
$cfg = @{}
foreach ($line in Get-Content $EnvPath) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
}
$Project = if ($cfg['COMPOSE_PROJECT_NAME']) { $cfg['COMPOSE_PROJECT_NAME'] } else { 'comp_demo' }
$Site    = if ($cfg['SITE_NAME']) { $cfg['SITE_NAME'] } else { 'frontend' }
$Bench   = "$Project-bench-1"

$running = (& docker ps --format '{{.Names}}') 2>&1
if (-not ("$running" -match [regex]::Escape($Bench))) {
    Warn "bench container $Bench is not running - cannot back up right now"
    Warn 'start the stack first (.\setup\start), then back up'
    exit 1
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dest = Join-Path $BackupRoot $stamp
New-Item -ItemType Directory -Force -Path $dest | Out-Null

Say "bench backup on site '$Site'"
$out = & docker exec -u frappe $Bench bash -lc "cd /home/frappe/frappe-bench && bench --site $Site backup" 2>&1
if ($LASTEXITCODE -ne 0) {
    Warn "bench backup failed: $($out | Select-Object -Last 3)"
    exit 1
}

$names = & docker exec -u frappe $Bench bash -lc "ls -1t /home/frappe/frappe-bench/sites/$Site/private/backups | head -2" 2>&1
$dump = ($names | Where-Object { $_ -match 'database\.sql\.gz$' } | Select-Object -First 1)
if (-not $dump) { Warn 'could not find the dump bench just wrote'; exit 1 }

Say "copying $dump to the host"
& docker cp "${Bench}:/home/frappe/frappe-bench/sites/$Site/private/backups/$dump" (Join-Path $dest $dump) | Out-Null
# bench's own site-config dump is not written without --backup-with-site-config,
# which this bench version does not accept; copy the live config instead.
& docker cp "${Bench}:/home/frappe/frappe-bench/sites/$Site/site_config.json" (Join-Path $dest 'site_config.json') | Out-Null

@"
comp_demo backup
site      : $Site
taken     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
source    : $Bench (docker volume ${Project}_db_data)
restore   : powershell -ExecutionPolicy Bypass -File .\setup\restore -Backup $stamp
"@ | Set-Content -Path (Join-Path $dest 'MANIFEST.txt') -Encoding utf8

Ok "backup written: backups\$stamp\$dump"

if ($RefreshSeed) {
    $seed = Join-Path $Root 'seed\frontend-database.sql.gz'
    Copy-Item (Join-Path $dest $dump) $seed -Force
    Ok "seed/frontend-database.sql.gz refreshed from this backup (commit it deliberately)"
}

# prune old backups
$all = Get-ChildItem $BackupRoot -Directory | Sort-Object Name -Descending
if ($all.Count -gt $Keep) {
    $all | Select-Object -Skip $Keep | ForEach-Object {
        Remove-Item $_.FullName -Recurse -Force
        Say "pruned old backup $($_.Name)"
    }
}
