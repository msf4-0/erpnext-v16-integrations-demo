# ensure_metabase.ps1
#
# Bring Metabase back to a usable "ERPNext Monitoring" dashboard after a
# `docker compose down`. Safe to re-run (idempotent):
#   1. the `metabase` schema + `metabase_user` + the SELECT grant on the live
#      site DB (they live in MariaDB, not in a Metabase volume, so a fresh
#      db_data volume silently loses them)
#   2. wait for /api/health
#   3. admin account + `ERPNext` data source (metabase-seed.ps1)
#   4. the 4 questions + `ERPNext Monitoring` dashboard, only if missing
#
#   powershell -File .\sandbox\scripts\ensure_metabase.ps1

param(
  [string]$BaseUrl    = "http://localhost:3005",
  [string]$DbContainer = "comp_demo-db-1",
  [string]$BenchContainer = "comp_demo-bench-1",
  [string]$SiteName   = "frontend",
  [string]$DbUser = "",
  [string]$DbPassword = "",
  [string]$AdminEmail = "",
  [string]$AdminPassword = "",
  [switch]$SkipSeed
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$envValues = @{}
$envFile = Join-Path $root '.env'
if (Test-Path $envFile) {
  foreach ($line in Get-Content -LiteralPath $envFile) {
    if ($line -match '^\s*#' -or $line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { continue }
    $envValues[$Matches[1]] = $Matches[2]
  }
}
if (-not $DbUser) { $DbUser = if ($envValues['METABASE_DB_USER']) { $envValues['METABASE_DB_USER'] } else { 'metabase_user' } }
if (-not $DbPassword) { $DbPassword = if ($envValues['METABASE_DB_PASS']) { $envValues['METABASE_DB_PASS'] } else { 'metabase_demo_2026' } }
if (-not $AdminEmail) { $AdminEmail = if ($envValues['METABASE_ADMIN_EMAIL']) { $envValues['METABASE_ADMIN_EMAIL'] } else { 'admin@demo.local' } }
if (-not $AdminPassword) { $AdminPassword = if ($envValues['METABASE_ADMIN_PASSWORD']) { $envValues['METABASE_ADMIN_PASSWORD'] } else { 'DemoPass2026!' } }

function Exec-Db([string]$SqlFile) {
  docker cp $SqlFile "${DbContainer}:/tmp/_ensure_metabase.sql" | Out-Null
  docker exec $DbContainer bash -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" < /tmp/_ensure_metabase.sql'
  if ($LASTEXITCODE -ne 0) { throw "metabase schema setup failed (exit $LASTEXITCODE)" }
}

# --- 1. resolve the live site DB name ---------------------------------------
$cfg = (docker exec $BenchContainer bash -c "cat /home/frappe/frappe-bench/sites/$SiteName/site_config.json" 2>$null | Out-String)
if ($cfg -notmatch '"db_name"\s*:\s*"([^"]+)"') { throw "could not read db_name from $SiteName/site_config.json" }
$siteDb = $Matches[1]
Write-Host "[1/4] site DB = $siteDb"

$dbUserSql = $DbUser.Replace("'", "''")
$dbPasswordSql = $DbPassword.Replace("'", "''")
$sql = @"
CREATE DATABASE IF NOT EXISTS metabase CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$dbUserSql'@'%' IDENTIFIED BY '$dbPasswordSql';
ALTER USER '$dbUserSql'@'%' IDENTIFIED BY '$dbPasswordSql';
GRANT ALL PRIVILEGES ON metabase.* TO '$dbUserSql'@'%';
GRANT SELECT, SHOW VIEW ON ``$siteDb``.* TO '$dbUserSql'@'%';
FLUSH PRIVILEGES;
"@
$tmp = Join-Path $env:TEMP "_ensure_metabase.sql"
Set-Content -Path $tmp -Value $sql -Encoding ascii
Exec-Db $tmp
Write-Host "      schema + user + grant ensured"

# --- 2. health --------------------------------------------------------------
Write-Host "[2/4] waiting for Metabase health ..."
$ok = $false
for ($i = 0; $i -lt 120; $i++) {
  try { $r = Invoke-RestMethod -Uri "$BaseUrl/api/health" -TimeoutSec 5; if ($r.status -eq 'ok') { $ok = $true; break } } catch { }
  Start-Sleep -Seconds 3
}
if (-not $ok) { throw "Metabase is not healthy at $BaseUrl - is the container running? docker start 'comp_demo-metabase-1'" }
Write-Host "      healthy"

# --- 3. admin + data source -------------------------------------------------
$sess = $null
try {
  $sess = Invoke-RestMethod -Uri "$BaseUrl/api/session" -Method Post -ContentType "application/json" `
    -Body (@{ username = $AdminEmail; password = $AdminPassword } | ConvertTo-Json)
} catch { $sess = $null }

if (-not $sess -and -not $SkipSeed) {
  Write-Host "[3/4] seeding admin + data source ..."
  & (Join-Path $root 'metabase-seed.ps1') -BaseUrl $BaseUrl -ErpnextDb $siteDb -DbUser $DbUser -DbPass $DbPassword -AdminEmail $AdminEmail -AdminPassword $AdminPassword
  $sess = Invoke-RestMethod -Uri "$BaseUrl/api/session" -Method Post -ContentType "application/json" `
    -Body (@{ username = $AdminEmail; password = $AdminPassword } | ConvertTo-Json)
} else {
  Write-Host "[3/4] admin session OK (seed skipped)"
}
$hdr = @{ "X-Metabase-Session" = $sess.id }

# --- 4. dashboard -----------------------------------------------------------
$existing = (Invoke-RestMethod -Uri "$BaseUrl/api/dashboard" -Headers $hdr) |
  Where-Object { $_.name -eq 'ERPNext Monitoring' } | Select-Object -First 1
if ($existing) {
  $d = Invoke-RestMethod -Uri "$BaseUrl/api/dashboard/$($existing.id)" -Headers $hdr
  Write-Host ("[4/4] dashboard id={0} already present with {1} cards" -f $d.id, ($d.dashcards | Measure-Object).Count)
} else {
  Write-Host "[4/4] building dashboard ..."
  & (Join-Path $PSScriptRoot 'build_metabase_dashboard.ps1') -BaseUrl $BaseUrl -AdminEmail $AdminEmail -AdminPassword $AdminPassword
  & (Join-Path $PSScriptRoot 'attach_metabase_dashcards.ps1') -BaseUrl $BaseUrl -AdminEmail $AdminEmail -AdminPassword $AdminPassword
}

Write-Host ""
Write-Host "Metabase: $BaseUrl  ($AdminEmail)"
