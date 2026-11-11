# ensure_metabase_app.ps1
#
# Installs the `metabase_integration` app (Metabase Dashboard + Metabase Settings
# doctypes and the `metabase-dashboard` desk page) and wires it to the running
# Metabase. Idempotent - safe on every converge.
#
#   powershell -File .\sandbox\scripts\ensure_metabase_app.ps1

param(
  [string]$BaseUrl        = "http://localhost:3005",
  [string]$DbContainer    = "comp_demo-db-1",
  [string]$BenchContainer = "comp_demo-bench-1",
  [string]$Repo           = "https://github.com/msf4-0/ERPNext-Metabase-Integration",
  [string]$AdminEmail     = "admin@demo.local",
  [string]$AdminPassword  = "DemoPass2026!",
  [switch]$SkipMetabaseConfig
)
$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot

function Log([string]$m) { Write-Host "      $m" }

# --- 1. static embedding on the Metabase side -------------------------------
if (-not $SkipMetabaseConfig) {
  $sess = Invoke-RestMethod -Uri "$BaseUrl/api/session" -Method Post -ContentType "application/json" `
    -Body (@{ username = $AdminEmail; password = $AdminPassword } | ConvertTo-Json)
  $hdr = @{ "X-Metabase-Session" = $sess.id }
  Invoke-RestMethod -Uri "$BaseUrl/api/setting/enable-embedding-static" -Method Put -Headers $hdr `
    -ContentType "application/json" -Body (@{ value = $true } | ConvertTo-Json) | Out-Null
  Invoke-RestMethod -Uri "$BaseUrl/api/dashboard/2" -Method Put -Headers $hdr `
    -ContentType "application/json" -Body (@{ enable_embedding = $true } | ConvertTo-Json) | Out-Null
  Log "static embedding enabled + dashboard 2 marked embeddable"
}

# --- 2. the signing secret lives in Metabase's own `setting` table ----------
# /api/setting/embedding-secret-key is marked sensitive and reads back empty,
# so read it straight from the Metabase metadata schema.
$sqlPath = Join-Path $env:TEMP "_mb_secret.sql"
Set-Content -Path $sqlPath -Value "select value from setting where ``key``='embedding-secret-key';" -Encoding ascii
docker cp $sqlPath "${DbContainer}:/tmp/_mb_secret.sql" | Out-Null
$secret = (docker exec $DbContainer bash -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -N -B metabase < /tmp/_mb_secret.sql' | Out-String).Trim()
if (-not $secret) { throw "embedding-secret-key not found in the metabase schema - run ensure_metabase.ps1 first" }
Log ("embedding secret found (" + $secret.Length + " chars)")

# --- 3. app present? --------------------------------------------------------
$has = (docker exec $BenchContainer bash -c "test -d /home/frappe/frappe-bench/apps/metabase_integration && echo yes || echo no" | Out-String).Trim()
if ($has -ne "yes") {
  Log "cloning $Repo ..."
  docker exec -u frappe $BenchContainer bash -lc "cd /home/frappe/frappe-bench/apps && git clone --depth 1 $Repo metabase_integration" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
} else {
  Log "app sources already present"
}

# --- 4. install + configure inside the container ---------------------------
docker cp (Join-Path $scriptDir 'metabase_app_setup.sh') "${BenchContainer}:/tmp/metabase_app_setup.sh" | Out-Null
docker cp (Join-Path $scriptDir 'metabase_app_config.py') "${BenchContainer}:/tmp/metabase_app_config.py" | Out-Null
docker exec -u frappe $BenchContainer bash /tmp/metabase_app_setup.sh $secret $BaseUrl
if ($LASTEXITCODE -ne 0) { throw "container setup failed (exit $LASTEXITCODE)" }

Write-Host ""
Write-Host "Metabase Dashboard: ERPNext site -> /app/metabase-dashboard, dashboard id 2 'ERPNext Monitoring'"
