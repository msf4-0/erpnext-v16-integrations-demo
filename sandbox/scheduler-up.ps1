<#
.SYNOPSIS
    Bring up the drag-and-drop production planner that sits beside ERPNext in the
    ERPNEXT-AI-FIX stack, and prove it is wired to the site.

.DESCRIPTION
    The planner is the operator's standalone Node/Express + React app
    (`scheduler/`), not a bench app. This script:

      1. builds + starts the `scheduler` compose service
      2. mints an API token for the dedicated planner user (planner@ai-fix.local)
         and writes it into sandbox/.env.ai-fix
      3. seeds demo manufacturing data (workstations, BOMs, Work Orders, Job Cards)
         when the site has none
      4. adds a "Production Planner" shortcut to the Manufacturing workspace
      5. verifies the three things that actually matter:
           - the planner answers /api/health
           - /api/schedule returns the seeded Work Orders
           - a reschedule round-trip changes planned_start_date in ERPNext

.PARAMETER Seed
    Seed demo manufacturing data even if Work Orders already exist.

.PARAMETER Reseed
    Delete existing Work Orders/Job Cards first, then seed (DESTRUCTIVE).

.PARAMETER RotateToken
    Mint a fresh API key/secret for the planner user.

.PARAMETER SkipBuild
    Start the existing image without rebuilding.

.EXAMPLE
    pwsh -File .\sandbox\scheduler-up.ps1
#>
[CmdletBinding()]
param(
    [switch]$Seed,
    [switch]$Reseed,
    [switch]$RotateToken,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$SandboxDir = $PSScriptRoot
$EnvPath = Join-Path $SandboxDir '.env.ai-fix'
$ComposeFile = Join-Path $SandboxDir 'docker-compose.erpnext-ai-fix.yml'
$ScriptsDir = Join-Path $SandboxDir 'scripts'
$Project = 'erpnext-ai-fix'

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}
function Write-Info([string]$Message) { Write-Host "  $Message" }
function Write-Warn([string]$Message) { Write-Host "  WARN: $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "  FAIL: $Message" -ForegroundColor Red }

function Read-EnvFile([string]$Path) {
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $idx = $line.IndexOf('=')
        $map[$line.Substring(0, $idx).Trim()] = $line.Substring($idx + 1).Trim()
    }
    return $map
}

function Set-EnvValue([string]$Path, [string]$Key, [string]$Value) {
    $lines = @(Get-Content -LiteralPath $Path)
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$([regex]::Escape($Key))=") {
            $lines[$i] = "$Key=$Value"
            $found = $true
        }
    }
    if (-not $found) { $lines += "$Key=$Value" }
    Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
}

# up.ps1 documents that `docker compose up` hangs on this host because the CLI
# has agent hooks attached to it. The standalone compose binary has no hooks, so
# prefer it when present.
$composeExe = (Get-Command docker-compose -ErrorAction SilentlyContinue).Source
if ($composeExe) {
    $composeBase = @('-p', $Project, '--env-file', $EnvPath, '-f', $ComposeFile)
} else {
    $composeExe = 'docker'
    $composeBase = @('compose', '-p', $Project, '--env-file', $EnvPath, '-f', $ComposeFile)
}

function Invoke-Compose {
    param([string[]]$Arguments)
    & $composeExe @($composeBase + $Arguments)
    return $LASTEXITCODE
}

$envMap = Read-EnvFile $EnvPath
$siteName = if ($envMap['SITE_NAME']) { $envMap['SITE_NAME'] } else { 'frontend' }
$erpPort = if ($envMap['ERPNEXT_PORT']) { $envMap['ERPNEXT_PORT'] } else { '8000' }
$schedPort = if ($envMap['SCHEDULER_PORT']) { $envMap['SCHEDULER_PORT'] } else { '3001' }
$plannerUrl = "http://localhost:$schedPort"

Write-Step "0/5  configuration"
Write-Info "site=$siteName  erpnext=http://localhost:$erpPort  planner=$plannerUrl"

# ---------------------------------------------------------------------------
Write-Step "1/5  building + starting the planner container"
if (-not $SkipBuild) {
    $rc = Invoke-Compose @('build', 'scheduler')
    if ($rc -ne 0) { throw 'compose build scheduler failed' }
}
$rc = Invoke-Compose @('up', '-d', '--no-deps', 'scheduler')
if ($rc -ne 0) { throw 'compose up scheduler failed' }

$healthy = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 3
    try {
        $r = Invoke-RestMethod -Uri "$plannerUrl/api/health" -TimeoutSec 5
        if ($r.status) { $healthy = $true; break }
    } catch { }
}
if (-not $healthy) { throw "planner did not become healthy at $plannerUrl/api/health" }
Write-Info "planner is up: $plannerUrl"

# ---------------------------------------------------------------------------
Write-Step "2/5  ERPNext API token for the planner"

# Stage the helper scripts the way up.ps1 stages its own: docker cp into the
# bench container, then run with the bench venv python.
Push-Location $SandboxDir
try {
    foreach ($helper in @('ai-fix-scheduler-token.py', 'seed_planner_demo.py', 'ai-fix-planner-workspace.py', 'planner_probe.py', 'planner_capacity_snapshot.py')) {
        $src = Join-Path $ScriptsDir $helper
        if (-not (Test-Path $src)) { throw "missing helper script: $src" }
        & docker cp $src "erpnext-ai-fix-bench-1:/tmp/$helper" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "docker cp failed for $helper" }
    }
} finally {
    Pop-Location
}
Write-Info 'helper scripts staged into the bench container (/tmp)'

$key = $envMap['SCHEDULER_ERPNEXT_API_KEY']
$secret = $envMap['SCHEDULER_ERPNEXT_API_SECRET']

function Set-PlannerToken([switch]$Force) {
    $current = Read-EnvFile $EnvPath
    if ($current['SCHEDULER_ERPNEXT_API_KEY'] -and $current['SCHEDULER_ERPNEXT_API_SECRET'] -and -not $Force) {
        Write-Info 'reusing the token already in .env.ai-fix (use -RotateToken to change it)'
        return
    }
    $extra = @()
    if ($Force) { $extra += '--rotate' }
    $out = & docker exec -u frappe -e "SITE_NAME=$siteName" erpnext-ai-fix-bench-1 `
        bash -lc "cd /home/frappe/frappe-bench && ./env/bin/python /tmp/ai-fix-scheduler-token.py $($extra -join ' ')" 2>&1
    $keyLine = ($out | Select-String -Pattern '^PLANNER_API_KEY=').Line
    $secretLine = ($out | Select-String -Pattern '^PLANNER_API_SECRET=').Line
    if (-not $keyLine -or -not $secretLine) { throw "could not mint an API token:`n$($out -join "`n")" }
    Set-EnvValue $EnvPath 'SCHEDULER_ERPNEXT_API_KEY' ($keyLine -replace '^PLANNER_API_KEY=', '')
    Set-EnvValue $EnvPath 'SCHEDULER_ERPNEXT_API_SECRET' ($secretLine -replace '^PLANNER_API_SECRET=', '')
    Write-Info 'token minted for planner@ai-fix.local and written to .env.ai-fix'
}

Set-PlannerToken -Force:$RotateToken

# The container reads the token from its environment, so a fresh token needs a
# restart to take effect.
$rc = Invoke-Compose @('up', '-d', '--no-deps', 'scheduler')
if ($rc -ne 0) { throw 'compose up scheduler (after token) failed' }

# ---------------------------------------------------------------------------
Write-Step "3/5  demo manufacturing data"
$seedArgs = @()
if ($Seed) { $seedArgs += '--force-orders' }
if ($Reseed) { $seedArgs += '--reset-orders' }
if ($Seed -or $Reseed) {
    $out = & docker exec -u frappe -e "SITE_NAME=$siteName" erpnext-ai-fix-bench-1 `
        bash -lc "cd /home/frappe/frappe-bench && ./env/bin/python /tmp/seed_planner_demo.py $($seedArgs -join ' ')" 2>&1
    $out | Select-String -Pattern 'MARK (work order|reset|bom|FAILED)' | ForEach-Object { Write-Info $_.Line }
    $summary = ($out | Select-String -Pattern '^SUMMARY ').Line
    if ($summary) { Write-Info $summary }
} else {
    # Counts come from planner_probe.py (staged in 2/5), not an inline python -c:
    # the Windows docker CLI mangles the nested quoting of a one-liner.
    $counts = & docker exec -u frappe -e "SITE_NAME=$siteName" erpnext-ai-fix-bench-1 `
        /home/frappe/frappe-bench/env/bin/python /tmp/planner_probe.py 2>&1
    $counts | Select-String -Pattern '^count (Work Order|Job Card|Workstation|BOM)\s' |
        ForEach-Object { Write-Info $_.Line }

    # The site DB is tmpfs, so a Docker restart can leave a provisioned-looking site
    # with zero manufacturing data. That also invalidates the planner's token (its
    # user is gone), hence the rotate + restart before seeding.
    $woMatch = $counts | Select-String -Pattern '^count Work Order\s+(\d+)'
    $woTotal = if ($woMatch) { [int]$woMatch.Matches[0].Groups[1].Value } else { 0 }
    if ($woTotal -eq 0) {
        Write-Warn 'no Work Orders on the site (tmpfs DB reset) - rotating the token and seeding'
        Set-PlannerToken -Force
        $rc = Invoke-Compose @('up', '-d', '--no-deps', 'scheduler')
        if ($rc -ne 0) { throw 'compose up scheduler (after token rotation) failed' }
        $out = & docker exec -u frappe -e "SITE_NAME=$siteName" erpnext-ai-fix-bench-1 `
            bash -lc "cd /home/frappe/frappe-bench && ./env/bin/python /tmp/seed_planner_demo.py" 2>&1
        $out | Select-String -Pattern 'MARK (work order|reset|bom|FAILED)' | ForEach-Object { Write-Info $_.Line }
    }
}

# ---------------------------------------------------------------------------
Write-Step "4/5  Manufacturing workspace shortcut"
$wsOut = & docker exec -u frappe -e "SITE_NAME=$siteName" erpnext-ai-fix-bench-1 `
    bash -lc "cd /home/frappe/frappe-bench && ./env/bin/python /tmp/ai-fix-planner-workspace.py --url $plannerUrl" 2>&1
$wsOut | Select-String -Pattern 'MARK|WARN' | ForEach-Object { Write-Info $_.Line }

# ---------------------------------------------------------------------------
Write-Step "5/5  verification"
$failed = @()

$health = Invoke-RestMethod -Uri "$plannerUrl/api/health" -TimeoutSec 10
Write-Info "planner /api/health -> $($health.status)"

try {
    $schedule = Invoke-RestMethod -Uri "$plannerUrl/api/schedule" -TimeoutSec 60
    $woCount = @($schedule.workOrders).Count
    $jcCount = @($schedule.jobCards).Count
    $wsCount = @($schedule.workstations).Count
    Write-Info "planner /api/schedule -> $woCount work orders, $jcCount job cards, $wsCount workstations"
    if ($woCount -eq 0) { $failed += 'schedule returned no work orders' }
} catch {
    $failed += "schedule failed: $($_.Exception.Message)"
}

if (@($schedule.workOrders).Count -gt 0) {
    # Snapshot the Job Card capacity plan first: the app's reschedule path
    # rewrites every Job Card it touches to a SINGLE schedule row, so the
    # round-trip below (and every real drag) erodes the seeded plan. The rows are
    # put back afterwards, which keeps repeat runs idempotent. Measured before
    # this existed: 65 rows -> 64 after one verification run.
    $snapDump = & docker exec -u frappe -e "SITE_NAME=$siteName" erpnext-ai-fix-bench-1 `
        bash -lc "cd /home/frappe/frappe-bench && ./env/bin/python /tmp/planner_capacity_snapshot.py --dump" 2>&1
    $countBefore = ($snapDump | Select-String -Pattern '^count rows\s+(\d+)').Matches[0].Groups[1].Value
    Write-Info "capacity plan snapshot: $countBefore job-card schedule rows"

    $wo = @($schedule.workOrders)[0]
    $original = $wo.planned_start_date
    $originalEnd = if ($wo.planned_end_date) { $wo.planned_end_date } else { $original }
    $target = ([datetime]$original).AddDays(2).ToString('yyyy-MM-dd 08:00:00')
    $body = @{ type = 'workorder'; docName = $wo.name; start = $target; end = $target } | ConvertTo-Json
    try {
        $res = Invoke-RestMethod -Uri "$plannerUrl/api/schedule/sync-reschedule" -Method Put `
            -ContentType 'application/json' -Body $body -TimeoutSec 60
        if (-not $res.success) { throw "API said: $($res.error)" }
        $after = Invoke-RestMethod -Uri "$plannerUrl/api/schedule" -TimeoutSec 60 |
            Select-Object -ExpandProperty workOrders | Where-Object { $_.name -eq $wo.name }
        if (([datetime]$after.planned_start_date).ToString('yyyy-MM-dd') -ne ([datetime]$target).ToString('yyyy-MM-dd')) {
            $failed += "reschedule did not persist: $($after.planned_start_date)"
        } else {
            Write-Info "reschedule $($wo.name): $original -> $($after.planned_start_date) (persisted in ERPNext)"
        }
        # put it back so repeated runs stay idempotent
        $restore = @{ type = 'workorder'; docName = $wo.name; start = $original; end = $originalEnd } | ConvertTo-Json
        Invoke-RestMethod -Uri "$plannerUrl/api/schedule/sync-reschedule" -Method Put `
            -ContentType 'application/json' -Body $restore -TimeoutSec 60 | Out-Null

        $snapRestore = & docker exec -u frappe -e "SITE_NAME=$siteName" erpnext-ai-fix-bench-1 `
            bash -lc "cd /home/frappe/frappe-bench && ./env/bin/python /tmp/planner_capacity_snapshot.py --restore" 2>&1
        $countAfter = ($snapRestore | Select-String -Pattern '^count rows\s+(\d+)').Matches[0].Groups[1].Value
        if ($countAfter -ne $countBefore) {
            $failed += "capacity plan not restored: $countBefore -> $countAfter rows"
        } else {
            Write-Info "capacity plan restored: $countAfter rows"
        }
    } catch {
        $failed += "reschedule round-trip failed: $($_.Exception.Message)"
    }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Fail 'verification problems:'
    $failed | ForEach-Object { Write-Fail " - $_" }
    exit 1
}
Write-Host 'Planner is integrated and verified.' -ForegroundColor Green
Write-Info "open:        $plannerUrl"
Write-Info "ERPNext:     http://localhost:$erpPort/app/work-order"
Write-Info "desk link:   Manufacturing workspace -> 'Production Planner'"
exit 0
