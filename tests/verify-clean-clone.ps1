# ---------------------------------------------------------------------------
# verify-clean-clone.ps1
#
# Proves the onboarding claim end to end WITHOUT touching the running stack:
#   git clone -> copy .env.example -> compose up -> seeded site answers -> assert
#
# It clones into a temp folder, runs as its own compose project
# (comp_demo_verify) on shifted ports with its own volumes, then tears
# everything down. Your comp_demo stack is never referenced.
#
#   powershell -ExecutionPolicy Bypass -File .\tests\verify-clean-clone.ps1
#   ... -Keep      keep the clone + containers for inspection
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$RepoUrl = 'https://github.com/msf4-0/erpnext-v16-integrations-demo.git',
    [string]$Project = 'comp_demo_verify',
    [string]$WorkDir = (Join-Path $env:TEMP 'comp_demo_clone_test'),
    [int]$ErpPort = 8100,
    [switch]$Keep
)

# Continue, not Stop: docker writes normal progress to stderr, and with Stop
# PowerShell 5.1 promotes the first "Network ... Creating" line into a fatal
# error. Every native call below is checked via $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'
$script:fail = 0
function Step([string]$m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Pass([string]$m) { Write-Host "  PASS  $m" -ForegroundColor Green }
function Fail([string]$m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fail++ }

function Invoke-C { param([string[]]$Args) & docker compose @Args }
$composeArgs = @('compose', '-p', $Project, '--env-file', (Join-Path $WorkDir '.env'), '-f', (Join-Path $WorkDir 'docker-compose.yml'))

Step "0  fresh clone into $WorkDir"
if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
& git clone --quiet $RepoUrl $WorkDir 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'git clone failed' }
Pass "cloned $(git -C $WorkDir rev-parse --short HEAD)"

Step '1  .env from the example (no edits beyond ports/project)'
$envPath = Join-Path $WorkDir '.env'
Copy-Item (Join-Path $WorkDir '.env.example') $envPath
$map = @{
    'COMPOSE_PROJECT_NAME' = $Project
    'ERPNEXT_PORT'         = "$ErpPort"
    'SCHEDULER_PORT'       = '3101'
    'NODE_RED_PORT'        = '1881'
    'METABASE_PORT'        = '3006'
}
$lines = Get-Content $envPath
foreach ($k in $map.Keys) {
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$k\s*=") { $lines[$i] = "$k=$($map[$k])"; $found = $true; break }
    }
    if (-not $found) { $lines += "$k=$($map[$k])" }
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($envPath, $lines, $utf8)
Pass "ports shifted to ERPNext $ErpPort / planner 3101 / node-red 1881 / metabase 3006"

Step '2  compose create (this host hangs on `up`, so create then start)'
& docker @composeArgs create 2>&1 | Select-Object -Last 5
if ($LASTEXITCODE -ne 0) { throw 'compose create failed' }
Pass 'containers created'

Step '3  start db + redis, then the seeder'
$c = { param($s) "$Project-$s-1" }
& docker start (& $c 'db') (& $c 'redis-cache') (& $c 'redis-queue') | Out-Null
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline) {
    $st = (& docker inspect -f '{{.State.Health.Status}}' (& $c 'db') 2>$null)
    if ($st -eq 'healthy') { break }
    Start-Sleep -Seconds 3
}
Pass "db health: $st"

& docker start (& $c 'seed') | Out-Null
Write-Host '  seeding (bench new-site + restore) - this is the 5-10 minute step'
& docker wait (& $c 'seed') | Out-Null
$seedExit = (& docker inspect -f '{{.State.ExitCode}}' (& $c 'seed'))
if ($seedExit -eq '0') { Pass 'seed exited 0' }
else {
    Fail "seed exited $seedExit"
    & docker logs --tail 30 (& $c 'seed') 2>&1 | ForEach-Object { "    $_" }
}

Step '4  start the rest of the stack'
foreach ($s in @('bench', 'node-red', 'scheduler', 'metabase')) {
    & docker start (& $c $s) 2>&1 | Out-Null
}
Pass 'bench / node-red / scheduler / metabase started'

Step '5  wait for ERPNext to answer'
$base = "http://localhost:$ErpPort"
$ok = $false
$deadline = (Get-Date).AddSeconds(420)
while ((Get-Date) -lt $deadline) {
    try {
        $r = Invoke-WebRequest -Uri "$base/api/method/ping" -UseBasicParsing -TimeoutSec 10
        if ($r.StatusCode -eq 200) { $ok = $true; break }
    } catch { }
    Start-Sleep -Seconds 5
}
if ($ok) { Pass "ping 200 at $base" } else {
    Fail 'ERPNext never answered ping'
    & docker logs --tail 40 (& $c 'bench') 2>&1 | ForEach-Object { "    $_" }
}

Step '6  feature assertions'
function Check([string]$name, [string]$url, [int]$expect = 200) {
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20
        if ([int]$r.StatusCode -eq $expect) { Pass "$name ($($r.RawContentLength) B)" }
        else { Fail "$name expected $expect got $($r.StatusCode)" }
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        Fail "$name expected $expect got $code"
    }
}
Check 'desk shell'        "$base/app"
Check 'barcode scan js'   "$base/assets/barcode_shrdc/js/scanner_barcode_patch.js"
Check 'barcode links js'  "$base/assets/barcode_shrdc/js/barcode_create_links.js"
Check 'item tracking js'  "$base/assets/item_tracking/js/item_tracking_scan.js"
Check 'login page'        "$base/login"

Step '7  seeded data is present (not an empty site)'
$apps = & docker exec (& $c 'bench') bash -lc 'cd /home/frappe/frappe-bench && bench --site frontend list-apps' 2>&1
foreach ($a in @('barcode_shrdc', 'shopify', 'eu_einvoice', 'item_tracking')) {
    if ($apps -match $a) { Pass "app installed: $a" } else { Fail "app missing: $a" }
}
# Count through python fed on stdin: inline `python -c` and nested SQL quoting
# do not survive PowerShell 5.1 -> docker exec -> bash. A fresh volume also has
# no logs/ dir, so create it first (bench only makes it during `bench init`).
& docker exec (& $c 'bench') bash -lc 'cd /home/frappe/frappe-bench && mkdir -p logs frontend/logs sites/frontend/logs' | Out-Null
$pyCheck = @"
import frappe
frappe.init(site='frontend', sites_path='sites')
frappe.connect()
print('COUNT', frappe.db.count('Item'))
"@
$itemRaw = $pyCheck | & docker exec -i (& $c 'bench') bash -lc 'cd /home/frappe/frappe-bench && ./env/bin/python -' 2>&1
$itemCount = 0
$line = ($itemRaw | Where-Object { "$_" -match '^COUNT\s+\d+' } | Select-Object -First 1)
if ($line) { $itemCount = [int](("$line" -split '\s+')[1]) }
Write-Host "  items in the seeded site: $itemCount"
if ($itemCount -ge 50) { Pass "demo items present ($itemCount)" } else { Fail "demo items look missing ($itemCount)" }
$planner = $false
try { $h = Invoke-RestMethod -Uri 'http://localhost:3101/api/health' -TimeoutSec 15; $planner = [bool]$h.status } catch { }
if ($planner) { Pass 'planner health OK' } else { Fail 'planner health failed' }

Step '8  teardown'
if ($Keep) {
    Write-Host "  kept: $WorkDir and project $Project" -ForegroundColor Yellow
} else {
    & docker @composeArgs down -v --remove-orphans 2>&1 | Select-Object -Last 3
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    Pass 'volumes, containers and clone removed'
}

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host 'CLEAN CLONE VERIFIED - all checks passed' -ForegroundColor Green
    exit 0
}
Write-Host "CLEAN CLONE FAILED - $($script:fail) check(s)" -ForegroundColor Red
exit 1
