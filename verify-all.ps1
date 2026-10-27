<#
.SYNOPSIS
    One-command end-to-end test of the comp_demo stack (milestones M1-M10).

.DESCRIPTION
    Runs the whole checklist the demo was built against and prints one
    PASS/FAIL line per milestone:

      M1  Node-RED is connected (editor, deployed flow, reaches bench)
      M2  ngrok routes + webhooks (public URL, POST /delivery-note through it)
      M3  stack live (all containers, ERPNext ping, all five apps)
      M4  Shopify master-data edits + the LIVE ERPNext -> Shopify push
      M5  storefront has the products
      M6  planner builds (Work Orders / Job Cards / Workstations / capacity)
      M7  drag-and-drop persists and keeps every Job Card capacity block
      M8  barcode/QR render incl. changed values + invalid EAN13 rejection
      M9  barcode/QR item tracking (scan, Delivery Note, Stock Entry, item_qr)
      M10 e-invoicing (EN 16931 CII XML + XRECHNUNG auto-attach)

    The frappe-level half lives in sandbox/scripts/verify-milestones.py and is
    executed inside the bench container, so this wrapper only needs docker +
    curl. Nothing is mutated except the throwaway AI-VERIFY-* item/customer that
    M4 creates and deletes again.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File F:\ERPNEXT\erpnext-build\verify-all.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipContainerSuite
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Project = 'comp_demo'
$ErpUrl = 'http://localhost:8000'
$NodeRedUrl = 'http://localhost:1880'
$PlannerUrl = 'http://localhost:3001'
$Store = '4e1075.myshopify.com'
$Site = 'frontend'
$Bench = "$Project-bench-1"
$NodeRed = "$Project-node-red-1"
$results = New-Object System.Collections.ArrayList

function Add-Result([string]$Id, [string]$Name, [bool]$Ok, [string]$Detail) {
    [void]$results.Add([pscustomobject]@{ Id = $Id; Check = $Name; Ok = $Ok; Detail = $Detail })
    $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
    $colour = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1,-10} {2}" -f $tag, $Id, $Detail) -ForegroundColor $colour
}

function Section([string]$Title) {
    Write-Host ''
    Write-Host ("--- $Title " + ('-' * [Math]::Max(0, 66 - $Title.Length))) -ForegroundColor Cyan
}

function Invoke-Curl([string]$Url, [string]$Method = 'GET', [string]$Body = '') {
    $args = @('-s', '-m', '45', '-o', 'NUL', '-w', '%{http_code}', '-X', $Method)
    if ($Body) { $args += @('-H', 'Content-Type: application/json', '-d', $Body) }
    $args += @('-H', 'ngrok-skip-browser-warning: 1')
    $args += $Url
    $code = (& curl.exe @args 2>$null)
    return [int]($code -as [int])
}

function Invoke-CurlText([string]$Url) {
    return (& curl.exe -s -m 45 -H 'ngrok-skip-browser-warning: 1' $Url 2>$null)
}

# ===========================================================================
# M3 - containers up
# ===========================================================================
Section 'M3  stack live'
$expected = @('bench', 'db', 'redis-cache', 'redis-queue', 'node-red', 'scheduler')
foreach ($svc in $expected) {
    $name = "$Project-$svc-1"
    $status = (docker inspect -f '{{.State.Status}}' $name 2>$null)
    $running = ($status -eq 'running')
    Add-Result "M3.$svc" "container $svc" $running ("{0} -> {1}" -f $name, $(if ($status) { $status } else { 'missing' }))
}

$pingCode = 0
try {
    $ping = Invoke-RestMethod -Uri "$ErpUrl/api/method/ping" -TimeoutSec 20
    $pingCode = 200
    Add-Result 'M3.ping' 'ERPNext ping' $true ("site message: " + $ping.message)
} catch {
    Add-Result 'M3.ping' 'ERPNext ping' $false $_.Exception.Message
}

# ===========================================================================
# M1 - Node-RED
# ===========================================================================
Section 'M1  Node-RED connected'
$nrCode = Invoke-Curl "$NodeRedUrl/"
Add-Result 'M1.editor' 'Node-RED editor' ($nrCode -eq 200) "GET $NodeRedUrl/ -> $nrCode"

$flows = Invoke-CurlText "$NodeRedUrl/flows"
$nodeCount = ([regex]::Matches($flows, '"type"')).Count
Add-Result 'M1.flow' 'flow deployed' ($nodeCount -gt 10) "$nodeCount nodes in /flows"

$bridge = (docker exec $NodeRed curl -s -m 15 'http://bench:8000/api/method/ping' 2>$null)
$bridgeOk = ($bridge -match 'pong|message')
Add-Result 'M1.bridge' 'node-red -> bench reachable' $bridgeOk (($bridge -replace '\s+', ' ').Trim() | ForEach-Object { $_.Substring(0, [Math]::Min(90, $_.Length)) })

foreach ($path in '/delivery-note', '/stock-entry', '/stock-recon') {
    $code = Invoke-Curl "$NodeRedUrl$path" 'POST' '{}'
    Add-Result "M1$path" "POST $path (local)" ($code -eq 200) "HTTP $code"
}

# ===========================================================================
# M2 - ngrok + webhooks
# ===========================================================================
Section 'M2  ngrok routes + webhooks'
$publicUrl = $null
foreach ($port in @(4040, 4041)) {
    try {
        $tunnels = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/tunnels" -TimeoutSec 4
        $candidate = ($tunnels.tunnels | Where-Object { $_.public_url } | Select-Object -First 1).public_url
        if ($candidate) { $publicUrl = $candidate; break }
    } catch { }
}
Add-Result 'M2.tunnel' 'ngrok tunnel up' ([bool]$publicUrl) ("public url: " + $(if ($publicUrl) { $publicUrl } else { 'none (agent API 4040/4041 unreachable)' }))

if ($publicUrl) {
    $rootCode = Invoke-Curl "$publicUrl/"
    Add-Result 'M2.public' 'public GET /' ($rootCode -eq 200) "GET $publicUrl/ -> $rootCode"

    $unknownCode = Invoke-Curl "$publicUrl/definitely-not-a-flow"
    Add-Result 'M2.404' 'unknown path -> 404 from Node-RED' ($unknownCode -eq 404) "GET /definitely-not-a-flow -> $unknownCode"

    foreach ($path in '/delivery-note', '/stock-entry', '/stock-recon') {
        $code = Invoke-Curl "$publicUrl$path" 'POST' '{}'
        Add-Result "M2$path" "POST $path via tunnel" ($code -eq 200) "HTTP $code through $publicUrl"
    }
}

# webhook records: enabled and pointing at the live host
$whScript = @"
import json
import os
import frappe

os.chdir('/home/frappe/frappe-bench/sites')
frappe.init(site='$Site', sites_path='.')
frappe.connect()
rows = frappe.get_all('Webhook', fields=['name', 'webhook_doctype', 'request_url', 'enabled'])
print('MARK_WH ' + json.dumps(rows))
"@
$whFile = Join-Path $env:TEMP '_wh_check.py'
Set-Content -LiteralPath $whFile -Value $whScript -Encoding ASCII
docker cp $whFile "${Bench}:/tmp/scripts/_wh_check.py" | Out-Null
docker exec -u root $Bench bash -lc 'chown frappe:frappe /tmp/scripts/_wh_check.py' | Out-Null
$whOut = docker exec $Bench bash -lc 'cd /home/frappe/frappe-bench && ./env/bin/python /tmp/scripts/_wh_check.py' 2>$null
$whLine = ($whOut | Select-String 'MARK_WH' | Select-Object -First 1)
if ($whLine) {
    $json = ($whLine -replace '.*MARK_WH ', '')
    $rows = $json | ConvertFrom-Json
    $host_ = if ($publicUrl) { ([uri]$publicUrl).Host } else { '' }
    $disabled = @($rows | Where-Object { $_.enabled -eq 0 }).Count
    $wrongHost = @($rows | Where-Object { $host_ -and ($_.request_url -notmatch [regex]::Escape($host_)) }).Count
    Add-Result 'M2.webhooks' 'webhook records enabled + wired' (($disabled -eq 0) -and ($wrongHost -eq 0)) ("$($rows.Count) webhooks, disabled=$disabled, wrong-host=$wrongHost")
    if ($Verbose) { $rows | Format-Table -AutoSize | Out-String | Write-Host }
} else {
    Add-Result 'M2.webhooks' 'webhook records enabled + wired' $false 'could not read Webhook records'
}

# ===========================================================================
# M6 - planner (host view)
# ===========================================================================
Section 'M6  planner service'
try {
    $health = Invoke-RestMethod -Uri "$PlannerUrl/api/health" -TimeoutSec 20
    Add-Result 'M6.health' 'planner health' ([bool]$health.status) ("status=" + $health.status)
} catch {
    Add-Result 'M6.health' 'planner health' $false $_.Exception.Message
}
try {
    $schedule = Invoke-RestMethod -Uri "$PlannerUrl/api/schedule" -TimeoutSec 120
    $wo = @($schedule.workOrders).Count
    $jc = @($schedule.jobCards).Count
    $ws = @($schedule.workstations).Count
    $bg = @($schedule.batchGroups).Count
    Add-Result 'M6.schedule' 'planner schedule payload' (($wo -gt 0) -and ($jc -gt 0)) "workOrders=$wo jobCards=$jc workstations=$ws batchGroups=$bg"
} catch {
    Add-Result 'M6.schedule' 'planner schedule payload' $false $_.Exception.Message
}

# The three planner tabs that used to be dead: Timers (route-order bug),
# Batch groups (needed the Virtual Work Order doctype) and Sales Forecast
# (needed Sales read permission for the planner user).
foreach ($tab in @(
        @{ Path = '/api/work-orders/timers'; Name = 'Timers tab' },
        @{ Path = '/api/batch-work-orders'; Name = 'Batch groups tab' },
        @{ Path = '/api/sales-forecast'; Name = 'Sales Forecast tab' }
    )) {
    try {
        $resp = Invoke-RestMethod -Uri ("$PlannerUrl" + $tab.Path) -TimeoutSec 120
        Add-Result ("M6" + $tab.Path) $tab.Name ($null -ne $resp) 'HTTP 200'
    } catch {
        Add-Result ("M6" + $tab.Path) $tab.Name $false $_.Exception.Message
    }
}

# M7 (UI) - the Job Cards must exist as draggable cards in BOTH views. Read-only:
# it counts DOM nodes and never drags anything. Needs node + playwright-core
# (see scheduler/ui-tests/README.md); skipped without them.
$uiDir = Join-Path $PSScriptRoot 'scheduler\ui-tests'
$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if ($nodeExe -and (Test-Path (Join-Path $uiDir 'node_modules\playwright-core'))) {
    Push-Location $uiDir
    $uiOut = (& $nodeExe 'ui-cards.mjs' 2>&1 | Out-String)
    Pop-Location
    try {
        $uiJson = $uiOut | ConvertFrom-Json
        $uiDetail = "matrix jobCards={0} draggable={1} stations={2} | calendar JC events={3} | console errors={4}" -f `
            $uiJson.matrix.jobCards, $uiJson.matrix.draggableJobCards, $uiJson.matrix.stations, `
            $uiJson.calendar.jobCardEvents, @($uiJson.console).Count
        Add-Result 'M7_UI' 'Job Cards rendered draggable (matrix + calendar)' ([bool]$uiJson.ok) $uiDetail
    } catch {
        Add-Result 'M7_UI' 'Job Cards rendered draggable (matrix + calendar)' $false ('unparseable output: ' + $uiOut.Substring(0, [Math]::Min(200, $uiOut.Length)))
    }
} else {
    Write-Host '  [SKIP] M7_UI  node or playwright-core missing (scheduler/ui-tests/README.md)'
}

# ===========================================================================
# M5 - storefront (read-only)
# ===========================================================================
Section 'M5  Shopify storefront'
$productHandle = 'planner-assembly-kit'
$pageCode = Invoke-Curl "https://$Store/products/$productHandle"
Add-Result 'M5.product' "product page /products/$productHandle" ($pageCode -eq 200) "HTTP $pageCode (429 = Shopify bot throttle, re-check with a browser)"
$homeCode = Invoke-Curl "https://$Store/"
Add-Result 'M5.home' 'storefront home' ($homeCode -eq 200) "HTTP $homeCode"

# ===========================================================================
# M4 / M6-M10 - frappe-level suite inside the container
# ===========================================================================
if (-not $SkipContainerSuite) {
    Section 'M4 + M6-M10  in-container suite (this takes a few minutes)'
    $host_suite = Join-Path $PSScriptRoot 'sandbox\scripts\verify-milestones.py'
    if (-not (Test-Path $host_suite)) {
        Add-Result 'M4.suite' 'in-container suite' $false "missing $host_suite"
    } else {
        docker cp $host_suite "${Bench}:/tmp/scripts/verify-milestones.py" | Out-Null
        docker exec -u root $Bench bash -lc 'chown frappe:frappe /tmp/scripts/verify-milestones.py' | Out-Null
        $out = docker exec $Bench bash -lc "cd /home/frappe/frappe-bench && SITE_NAME=$Site PLANNER_URL=http://scheduler:3000 ./env/bin/python /tmp/scripts/verify-milestones.py" 2>&1
        $out | ForEach-Object { Write-Host $_ }
        foreach ($line in ($out | Select-String '^MARK_(M\d+\w*) (PASS|FAIL|TRACE) (.*)$')) {
            $id = $line.Matches[0].Groups[1].Value
            $verdict = $line.Matches[0].Groups[2].Value
            $detail = $line.Matches[0].Groups[3].Value
            if ($verdict -ne 'TRACE') {
                Add-Result $id $id ($verdict -eq 'PASS') $detail
            }
        }
        $summary = ($out | Select-String '^MARK_SUMMARY').Line
        if (-not $summary) { Add-Result 'M4.suite' 'in-container suite' $false 'no MARK_SUMMARY - the suite crashed, see output above' }
    }
}

# ===========================================================================
# summary
# ===========================================================================
Write-Host ''
Write-Host ('=' * 72) -ForegroundColor DarkCyan
$failed = @($results | Where-Object { -not $_.Ok })
$passed = @($results | Where-Object { $_.Ok })
Write-Host ("  RESULT: {0} passed, {1} failed, {2} checks" -f $passed.Count, $failed.Count, $results.Count) -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Yellow' })
Write-Host ('=' * 72) -ForegroundColor DarkCyan
if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host '  FAILED:' -ForegroundColor Red
    $failed | ForEach-Object { Write-Host ("   - {0}: {1}" -f $_.Id, $_.Detail) -ForegroundColor Red }
}
Write-Host ''
Write-Host ("  ERPNext  : $ErpUrl   (Administrator / admin)")
Write-Host ("  Planner  : $PlannerUrl")
Write-Host ("  Node-RED : $NodeRedUrl")
if ($publicUrl) { Write-Host ("  Tunnel   : $publicUrl") }
Write-Host ''

exit ([int]($failed.Count -gt 0))
