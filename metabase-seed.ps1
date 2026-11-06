# metabase-seed.ps1
#
# One-time (idempotent) seeding of Metabase for the comp_demo stack:
#   1. wait for Metabase to become healthy at $BaseUrl
#   2. create the initial admin account (only on first run)
#   3. register the ERPNext site DB as a Metabase data source over the compose
#      network (host `db`, port 3306)
#
# Run from the host after `docker compose up -d metabase`:
#   powershell -File F:\ERPNEXT\erpnextcomp_demo\metabase-seed.ps1
#
# Values mirror the Metabase block in .env. Override any with -<Param> <value>.

param(
  [string]$BaseUrl       = "http://localhost:3005",
  [string]$DbHost        = "db",
  [int]   $DbPort        = 3306,
  [string]$ErpnextDb     = "_35e1999d62da474b",
  [string]$DbUser        = "metabase_user",
  [string]$DbPass        = "metabase_demo_2026",
  [string]$AdminEmail    = "admin@demo.local",
  [string]$AdminPassword = "DemoPass2026!",
  [string]$DataSourceName = "ERPNext"
)

$ErrorActionPreference = "Stop"

function Wait-Health {
  for ($i = 0; $i -lt 600; $i++) {
    try {
      $r = Invoke-RestMethod -Uri "$BaseUrl/api/health" -TimeoutSec 5
      if ($r.status -eq "ok") { return }
    } catch { }
    if (($i % 20) -eq 0) { Write-Host "      still starting (elapsed $($i*2)s) ..." }
    Start-Sleep -Seconds 2
  }
  throw "Metabase did not become healthy within ~20 minutes at $BaseUrl"
}

Write-Host "[1/4] Waiting for Metabase health at $BaseUrl ..."
Wait-Health
Write-Host "      Metabase is healthy."

Write-Host "[2/4] Ensuring admin account ..."
# Metabase v0.58+ requires a setup token on first run; it is exposed on the
# public /api/session/properties endpoint while the instance is unconfigured.
$setupBody = @{
  user  = @{ first_name = "Demo"; last_name = "Admin"; email = $AdminEmail; password = $AdminPassword }
  prefs = @{ site_name = "comp_demo"; allow_tracking = $false }
}
try {
  $props = Invoke-RestMethod -Uri "$BaseUrl/api/session/properties" -TimeoutSec 5
  if ($props.'setup-token') { $setupBody.token = $props.'setup-token' }
} catch { }
$setupJson = $setupBody | ConvertTo-Json -Depth 5
try {
  Invoke-RestMethod -Uri "$BaseUrl/api/setup" -Method Post -ContentType "application/json" -Body $setupJson | Out-Null
  Write-Host "      Admin account created ($AdminEmail)."
} catch {
  if ($_.Exception.Message -match "already|set up") {
    Write-Host "      Metabase is already set up; keeping existing admin."
  } else {
    Write-Host "      Setup returned: $($_.Exception.Message) (continuing)"
  }
}

Write-Host "[3/4] Authenticating ..."
$sess = Invoke-RestMethod -Uri "$BaseUrl/api/session" -Method Post -ContentType "application/json" `
  -Body (@{ username = $AdminEmail; password = $AdminPassword } | ConvertTo-Json)
$hdr = @{ "X-Metabase-Session" = $sess.id }

$dbs = Invoke-RestMethod -Uri "$BaseUrl/api/database" -Headers $hdr
$existing = @($dbs.data) | Where-Object { $_.name -eq $DataSourceName }

if ($existing) {
  Write-Host "      Data source '$DataSourceName' already exists (id=$($existing.id)); skipping."
} else {
  $dbBody = @{
    engine       = "mysql"
    name         = $DataSourceName
    details      = @{
      host     = $DbHost
      port     = $DbPort
      dbname   = $ErpnextDb
      user     = $DbUser
      password = $DbPass
      ssl      = $false
    }
    is_full_sync = $true
  } | ConvertTo-Json -Depth 6
  try {
    $created = Invoke-RestMethod -Uri "$BaseUrl/api/database" -Method Post -Headers $hdr -ContentType "application/json" -Body $dbBody
    Write-Host "      Registered '$DataSourceName' data source (id=$($created.id))."
  } catch {
    Write-Host "      FAILED to register ERPNext data source:"
    Write-Host "        $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Host "        $($_.ErrorDetails.Message)" }
    throw
  }
}

Write-Host "[4/4] Databases known to Metabase:"
$dbs = Invoke-RestMethod -Uri "$BaseUrl/api/database" -Headers $hdr
$dbs.data | ForEach-Object { Write-Host ("      - {0} ({1})" -f $_.name, $_.engine) }

Write-Host ""
Write-Host "Done. Open $BaseUrl and sign in as $AdminEmail"
