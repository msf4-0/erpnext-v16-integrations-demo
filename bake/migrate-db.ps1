<#
.SYNOPSIS
    Migrate the comp_demo site DB from tmpfs to the durable `db_data` named
    volume (bake track 2b).

.DESCRIPTION
    The DB datadir currently lives in tmpfs (lost on stop). This script:
      1. dumps the site database only (consistent snapshot)
      2. removes the old db container (tmpfs data discarded — we have the dump)
      3. recreates + starts db against the now-persistent `db_data` volume
      4. restores the dump
      5. verifies the site DB + table count via the running site

    The restore pays this host's slow container-storage DDL cost ONCE (~900
    tables); after that the data survives restarts.

    Requires: the compose file already points db at `db_data:/var/lib/mysql`.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$DemoDir  = $PSScriptRoot | Split-Path -Parent
$Compose  = Join-Path $DemoDir 'docker-compose.yml'
$EnvPath  = Join-Path $DemoDir '.env'
$VersionsPath = Join-Path $DemoDir 'versions.env'
$Cache    = Join-Path $DemoDir '.cache'
$Project  = 'comp_demo'
$Dump     = Join-Path $Cache 'comp_demo-site.sql'
$AllDump  = Join-Path $Cache 'comp_demo-site-dump.sql'   # full all-databases safety net

New-Item -ItemType Directory -Force -Path $Cache | Out-Null

$compose = if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
    @('docker-compose', '-p', $Project, '--env-file', $EnvPath, '--env-file', $VersionsPath, '-f', $Compose)
} else {
    @('docker', 'compose', '-p', $Project, '--env-file', $EnvPath, '--env-file', $VersionsPath, '-f', $Compose)
}
function Run($exe, $args) { & $exe @args 2>&1 | ForEach-Object { "$_" } }

# Site DB name is the frappe hashed name (e.g. _35e1999d62da474b), not 'frontend'.
Write-Host '== 1. resolve site DB name =='
$dbName = (& docker exec comp_demo-db-1 sh -lc "mariadb -uroot -padmin -N -e 'show databases;'" 2>$null |
    Where-Object { $_ -match '^_[0-9a-f]{16}$' } | Select-Object -First 1)
if (-not $dbName) { throw 'could not resolve the site database name from the running db' }
Write-Host "   site DB: $dbName"

Write-Host '== 2. dump site database (consistent) =='
(& docker exec comp_demo-db-1 sh -lc "mariadb-dump --single-transaction --routines --triggers -uroot -padmin $dbName" 2>$null |
    Set-Content -LiteralPath $Dump -Encoding utf8)
Write-Host "   dump bytes: $((Get-Item $Dump).Length)"

Write-Host '== 3. recreate db container on the db_data volume =='
& docker rm -f comp_demo-db-1 | Out-Null
if (& $compose[0] $compose[1..($compose.Count-1)] create db 2>&1 | Select-Object -Last 1 | Out-String | ForEach-Object { $_ }) { }
if (& docker start comp_demo-db-1 2>&1 | Select-Object -Last 1) { }

Write-Host '== 4. wait for MariaDB ready =='
$deadline = (Get-Date).AddSeconds(120)
$ready = $false
while ((Get-Date) -lt $deadline) {
    if (& docker exec comp_demo-db-1 sh -lc "mariadb -uroot -padmin -e 'select 1;'" 2>$null) { $ready = $true; break }
    Start-Sleep -Seconds 3
}
if (-not $ready) { throw 'new db container did not become ready' }
Write-Host '   db ready'

Write-Host '== 5. restore site database (slow on this host) =='
Get-Content -LiteralPath $Dump -Raw | docker exec -i comp_demo-db-1 sh -lc "mariadb -uroot -padmin" 2>&1 | Where-Object { $_ } | Select-Object -First 20
Write-Host "   restore exit: $LASTEXITCODE"

Write-Host '== 6. verify =='
$tables = (& docker exec comp_demo-db-1 sh -lc "mariadb -uroot -padmin -N -e 'select count(*) from information_schema.tables where table_schema=\"$dbName\";'" 2>$null)
Write-Host "   tables in $dbName : $tables"

$site = (& docker exec comp_demo-bench-1 sh -lc "cd /home/frappe/frappe-bench && bench --site frontend list-apps" 2>&1 | Select-Object -First 5)
Write-Host "   site apps: $($site -join '; ')"
Write-Host 'DONE'
