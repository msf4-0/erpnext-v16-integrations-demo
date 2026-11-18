<#
.SYNOPSIS
    Restore a host backup made by backup.ps1 into the running stack.

.DESCRIPTION
    Copies `backups/<name>/*-database.sql.gz` into the bench container and runs
    `bench --site <site> restore`. The restore REPLACES the site database, so
    this script takes a safety backup first unless -SkipSafetyBackup is passed.

    Stop anything that writes during a restore: setup.ps1 starts the scheduler
    and worker, which is exactly what you do not want mid-restore, so they are
    paused here and started again at the end.

.PARAMETER Backup
    Folder name under backups/, e.g. 20261116-101500. Omit to list what exists.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup\restore
    powershell -ExecutionPolicy Bypass -File .\setup\restore -Backup 20261116-101500
#>
param(
    [string]$Backup,
    [switch]$SkipSafetyBackup
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$BackupRoot = Join-Path $Root 'backups'

if (-not $Backup) {
    Write-Host 'Available backups:'
    if (Test-Path $BackupRoot) {
        Get-ChildItem $BackupRoot -Directory | Sort-Object Name -Descending |
            ForEach-Object { Write-Host "  $($_.Name)  ($((Get-ChildItem $_.FullName -Filter '*database.sql.gz').Name))" }
    } else { Write-Host '  none' }
    exit 0
}

$dir = Join-Path $BackupRoot $Backup
if (-not (Test-Path $dir)) { Write-Host "No such backup: $Backup" -ForegroundColor Red; exit 1 }
$dump = (Get-ChildItem $dir -Filter '*database.sql.gz' | Select-Object -First 1).Name
if (-not $dump) { Write-Host "No database dump in $dir" -ForegroundColor Red; exit 1 }

$cfg = @{}
foreach ($line in Get-Content (Join-Path $Root '.env')) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
}
$Project = if ($cfg['COMPOSE_PROJECT_NAME']) { $cfg['COMPOSE_PROJECT_NAME'] } else { 'comp_demo' }
$Site    = if ($cfg['SITE_NAME']) { $cfg['SITE_NAME'] } else { 'frontend' }
$Bench   = "$Project-bench-1"
$RootPw  = if ($cfg['DB_ROOT_PASSWORD']) { $cfg['DB_ROOT_PASSWORD'] } else { 'admin' }

Write-Host ''
Write-Host "This REPLACES the database of site '$Site' with backups\$Backup\$dump" -ForegroundColor Yellow
$answer = Read-Host 'Type RESTORE to continue'
if ($answer -ne 'RESTORE') { Write-Host 'aborted'; exit 1 }

if (-not $SkipSafetyBackup) {
    Write-Host '  ...   taking a safety backup first'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'backup.ps1')
    if ($LASTEXITCODE -ne 0) { Write-Host 'safety backup failed - aborting' -ForegroundColor Red; exit 1 }
}

# Pause background writers for the duration of the restore.
& docker exec -u frappe $Bench bash -lc "pkill -f 'frappe worker' 2>/dev/null; pkill -f 'frappe schedule' 2>/dev/null; true" | Out-Null

Write-Host "  ...   copying $dump into the container"
& docker cp (Join-Path $dir $dump) "${Bench}:/tmp/restore-database.sql.gz" | Out-Null
& docker exec -u frappe $Bench bash -lc "chmod 644 /tmp/restore-database.sql.gz" | Out-Null

Write-Host '  ...   bench restore (this replaces the database)'
& docker exec -u frappe $Bench bash -lc "cd /home/frappe/frappe-bench && bench --site $Site restore /tmp/restore-database.sql.gz --mariadb-root-password '$RootPw'"
if ($LASTEXITCODE -ne 0) { Write-Host 'restore FAILED - the previous data may still be intact; inspect the output above' -ForegroundColor Red; exit 1 }

& docker exec -u frappe $Bench bash -lc "cd /home/frappe/frappe-bench && bench --site $Site migrate --skip-search-index; bench --site $Site clear-cache" | Out-Null

Write-Host ''
Write-Host '  Restored. Run .\setup\setup to restart the scheduler/worker and verify.' -ForegroundColor Green
