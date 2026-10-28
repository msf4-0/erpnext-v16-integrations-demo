<#
.SYNOPSIS
    Consistent, repeatable setup for the ERPNext comp_demo build.

.DESCRIPTION
    `up.ps1` builds the stack from zero (25-35 min) and is correct for a blank
    machine. This script is the *converge* step you run on every subsequent
    session: it makes an existing (or half-broken) stack match the configuration
    in .env, and proves it. Safe to run any number of times.

    What it reconciles, in order:
      1. preflight  - docker engine, python, compose file, project files
      2. .env       - absolute paths and stale secrets self-heal to this folder
                      (the folder gets renamed; hard-coded paths do not)
      3. containers - created + started (never `compose up`, which hangs here)
      4. bench      - site present, /home/frappe/logs present
      5. ERPNext    - Administrator API token validated; rotated if it 401s
      6. Shopify    - 24 h Admin API token minted from client credentials
      7. Node-RED   - flows.json rebuilt with live tokens, container remounted
                      when its bind mount points at a stale path
      8. tunnel     - ngrok up, public URL read back from the agent API
      9. webhooks   - the three ERPNext Webhooks pointed at that URL + enabled
     10. verify     - HTTP checks local and through the tunnel; non-zero exit
                      if anything is still wrong

    Exit codes: 0 = all checks pass, 1 = something is still broken.

.PARAMETER VerifyOnly
    Change nothing. Report the state of every component.

.PARAMETER Full
    Rebuild everything from zero first by delegating to up.ps1, then converge.
    Takes 25-35 minutes.

.PARAMETER Wipe
    Destructive; only with -Full. Passes -Fresh to up.ps1, which deletes the
    volumes. The site database is tmpfs, so this is how you get a clean slate.

.PARAMETER SkipShopify
    Do not mint a new Shopify token (leave .env and the flow unchanged).

.PARAMETER ForceFlow
    Rebuild and redeploy the Node-RED flow even if it looks healthy.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup.ps1
    # the everyday command: converge + verify, ~2-4 min

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup.ps1 -VerifyOnly
    # read-only health report, ~30 s

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Full
    # clean machine or after `docker compose down`: full rebuild, then verify
#>
[CmdletBinding()]
param(
    [switch]$VerifyOnly,
    [switch]$Full,
    [switch]$Wipe,
    [switch]$SkipShopify,
    [switch]$ForceFlow
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# paths / identity
# ---------------------------------------------------------------------------
$DemoDir    = $PSScriptRoot
$SandboxDir = Join-Path $DemoDir 'sandbox'
$EnvPath    = Join-Path $DemoDir '.env'
$ComposeFile = Join-Path $DemoDir 'docker-compose.yml'
$FlowPath   = Join-Path $SandboxDir 'node-red\flows.json'
$FlowSrc    = Join-Path $SandboxDir 'node-red\source-flow.json'
$Builder    = Join-Path $SandboxDir 'node-red\build-flows.py'
$FlowCheck  = Join-Path $SandboxDir 'scripts\check-flow.py'
$WhScript   = Join-Path $SandboxDir 'scripts\ai-fix-wire-webhooks.sh'
$Project    = 'comp_demo'
$BenchName  = "$Project-bench-1"
$NodeRedName = "$Project-node-red-1"
$MandatoryServices = @('db', 'redis-cache', 'redis-queue', 'bench', 'node-red')

$script:Issues = New-Object System.Collections.Generic.List[string]
$script:Fixed = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$m) {
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
    Write-Host "  $m" -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
}
function Write-Ok([string]$m)   { Write-Host "  OK    $m" -ForegroundColor Green }
function Write-Info([string]$m) { Write-Host "  ...   $m" }
function Write-Change([string]$m) {
    Write-Host "  FIXED $m" -ForegroundColor Yellow
    $script:Fixed.Add($m)
}
function Write-Warn([string]$m) { Write-Host "  WARN  $m" -ForegroundColor Yellow }
function Write-Fail([string]$m) {
    Write-Host "  FAIL  $m" -ForegroundColor Red
    $script:Issues.Add($m)
}

# ---------------------------------------------------------------------------
# native / docker helpers
# ---------------------------------------------------------------------------
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [switch]$Capture)
    # Native tools write progress to stderr; with $ErrorActionPreference='Stop'
    # PowerShell 5.1 promotes those lines to terminating errors. Relax locally.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $Exe @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    $lines = @(foreach ($item in $raw) {
        if ($item -is [System.Management.Automation.ErrorRecord]) { $item.Exception.Message }
        else { "$item" }
    })
    if ($Capture) { return [pscustomobject]@{ Output = ($lines -join "`n"); Code = $code } }
    $lines | ForEach-Object { Write-Host "  $_" }
    return $code
}
function Invoke-Docker {
    param([string[]]$Arguments, [switch]$Capture)
    Invoke-Native -Exe 'docker' -Arguments $Arguments -Capture:$Capture
}

# `docker compose up` hangs on this host (Docker Desktop agent hooks), so the
# project uses the standalone compose binary + create/start. Mirror up.ps1.
$script:ComposeExe = (Get-Command docker-compose -ErrorAction SilentlyContinue).Source
if ($script:ComposeExe) { $script:ComposeArgs = @('-p', $Project, '--env-file', $EnvPath, '-f', $ComposeFile) }
else { $script:ComposeExe = 'docker'; $script:ComposeArgs = @('compose', '-p', $Project, '--env-file', $EnvPath, '-f', $ComposeFile) }

function Invoke-Compose {
    param([string[]]$Arguments, [switch]$Capture)
    Invoke-Native -Exe $script:ComposeExe -Arguments ($script:ComposeArgs + $Arguments) -Capture:$Capture
}
function Invoke-Bench {
    param([string]$Command, [switch]$Capture)
    Invoke-Docker -Arguments @('exec', '-u', 'frappe', $BenchName, 'bash', '-lc', $Command) -Capture:$Capture
}
function Invoke-BenchRoot {
    param([string]$Command, [switch]$Capture)
    Invoke-Docker -Arguments @('exec', '-u', 'root', $BenchName, 'bash', '-lc', $Command) -Capture:$Capture
}

# ---------------------------------------------------------------------------
# .env helpers (BOM-safe: Windows PowerShell's UTF8 encoder adds a BOM, and
# docker compose then fails to parse the FIRST variable in the file)
# ---------------------------------------------------------------------------
function Read-EnvFile([string]$Path) {
    $table = @{}
    if (-not (Test-Path $Path)) { return $table }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { $table[$Matches[1]] = $Matches[2] }
    }
    return $table
}
function Set-EnvValue([string]$Path, [string]$Key, [string]$Value) {
    $lines = [System.Collections.Generic.List[string]](@(Get-Content -LiteralPath $Path))
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$([regex]::Escape($Key))\s*=") {
            if ($lines[$i] -ceq "$Key=$Value") { return $false }   # no change
            $lines[$i] = "$Key=$Value"; $found = $true; break
        }
    }
    if (-not $found) { $lines.Add("$Key=$Value") }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $lines, $utf8)
    return $true
}

function Test-PlaceholderValue([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    $v = $Value.Trim()
    if ($v -eq '__FILL_ME__' -or $v -ieq 'changeme' -or $v -ieq 'change-me') { return $true }
    if ($v -match '^x+$' -or $v -match '^your[-_ ]?') { return $true }
    return $false
}

function Prompt-ShopifyCredentials([hashtable]$cfg, [string]$EnvPath) {
    # A fresh clone has no .env (git-ignored) and placeholder Shopify values in
    # .env.example. Collect what is missing so a new user never needs the
    # original author's secrets. Every answer is optional (Enter keeps the
    # current value) and is persisted to .env immediately.
    $store = $cfg['SHOPIFY_STORE']
    if (Test-PlaceholderValue $store) {
        Write-Host ''
        $store = Read-Host 'Shopify store host (e.g. your-store.myshopify.com)'
        if ($store) { Set-EnvValue $EnvPath 'SHOPIFY_STORE' $store | Out-Null; Write-Change 'SHOPIFY_STORE set' }
    }

    $clientId     = $cfg['SHOPIFY_CLIENT_ID']
    $clientSecret = $cfg['SHOPIFY_CLIENT_SECRET']
    $accessToken  = $cfg['SHOPIFY_ACCESS_TOKEN']
    $haveClient   = (-not (Test-PlaceholderValue $clientId)) -and (-not (Test-PlaceholderValue $clientSecret))
    $haveToken    = -not (Test-PlaceholderValue $accessToken)

    if (-not $haveClient -and -not $haveToken) {
        Write-Host ''
        Write-Warn 'Shopify is not configured. Provide client credentials (recommended - setup.ps1 then mints a fresh 24 h Admin API token) or a ready access token.'
        $mode = Read-Host 'Enter 1 for client credentials, 2 for a ready access token'
        if ($mode -eq '2') {
            $accessToken = Read-Host 'Shopify Admin API access token (shpat_...)'
            if ($accessToken) { Set-EnvValue $EnvPath 'SHOPIFY_ACCESS_TOKEN' $accessToken | Out-Null; Write-Change 'SHOPIFY_ACCESS_TOKEN set' }
        } else {
            if (Test-PlaceholderValue $clientId) {
                $clientId = Read-Host 'Shopify client ID (shpca_...)'
                if ($clientId) { Set-EnvValue $EnvPath 'SHOPIFY_CLIENT_ID' $clientId | Out-Null; Write-Change 'SHOPIFY_CLIENT_ID set' }
            }
            if (Test-PlaceholderValue $clientSecret) {
                $clientSecret = Read-Host 'Shopify client secret (shpss_...)'
                if ($clientSecret) { Set-EnvValue $EnvPath 'SHOPIFY_CLIENT_SECRET' $clientSecret | Out-Null; Write-Change 'SHOPIFY_CLIENT_SECRET set' }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
function Test-ApiToken([string]$Token) {
    if (-not $Token) { return $false }
    try {
        $r = Invoke-RestMethod -Uri 'http://localhost:8000/api/method/frappe.auth.get_logged_user' `
            -Headers @{ Authorization = "token $Token" } -TimeoutSec 20
        return [bool]$r.message
    } catch { return $false }
}
function Test-ShopifyToken([string]$Token, [string]$Store, [string]$Version) {
    # A cheap authenticated GET: 200 means the 24 h token is still alive.
    if (-not $Token) { return $false }
    try {
        $null = Invoke-RestMethod -Uri "https://$Store/admin/api/$Version/shop.json" `
            -Headers @{ 'X-Shopify-Access-Token' = $Token } -TimeoutSec 30
        return $true
    } catch { return $false }
}
function Get-HttpStatus([string]$Url, [string]$Method = 'GET', [string]$Body = $null, [hashtable]$Headers = @{}) {
    try {
        $p = @{ Uri = $Url; UseBasicParsing = $true; TimeoutSec = 25; Method = $Method; Headers = $Headers }
        if ($Body) { $p.Body = $Body; $p.ContentType = 'application/json' }
        return [int](Invoke-WebRequest @p).StatusCode
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return 0
    }
}

# ---------------------------------------------------------------------------
# HTTP helpers (cont.): Invoke-Api wraps Invoke-RestMethod so callers never
# throw on 4xx/5xx; it returns { Ok, Status, Data, Error } like the sibling
# shopify-setup script's helper. Step 5b relies on it.
# ---------------------------------------------------------------------------
function Invoke-Api {
    param(
        [string]$Method = 'GET',
        [string]$Uri,
        $Body,
        [hashtable]$Headers = @{},
        [string]$ContentType,
        [int]$TimeoutSec = 45
    )
    $p = @{ Method = $Method; Uri = $Uri; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $p['Body'] = $Body }
    if ($Headers) { $p['Headers'] = $Headers }
    if ($ContentType) { $p['ContentType'] = $ContentType }
    try {
        $data = Invoke-RestMethod @p
        return [pscustomobject]@{ Ok = $true; Status = 200; Data = $data; Error = $null }
    } catch {
        $status = 0
        try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { $status = 0 }
        return [pscustomobject]@{ Ok = $false; Status = $status; Data = $null; Error = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------
# 0. bootstrap .env (a fresh clone has no .env - it is git-ignored)
# ---------------------------------------------------------------------------
if (-not $VerifyOnly -and -not (Test-Path $EnvPath)) {
    $example = Join-Path $DemoDir '.env.example'
    if (Test-Path $example) {
        Copy-Item $example $EnvPath -Force
        Write-Change '.env created from .env.example (Shopify credentials are prompted next)'
    } else {
        New-Item -ItemType File -Path $EnvPath -Force | Out-Null
        Write-Warn 'no .env.example found - created an empty .env'
    }
}

# ---------------------------------------------------------------------------
# 1. preflight
# ---------------------------------------------------------------------------
Write-Step '1/10  preflight'

foreach ($f in @($ComposeFile, $EnvPath, $Builder, $FlowSrc, $FlowCheck, $WhScript)) {
    if (-not (Test-Path $f)) { Write-Fail "missing required file: $f" }
}
if ($script:Issues.Count -gt 0) { throw "preflight failed (see above)" }

$dockerVer = (Invoke-Docker -Arguments @('version', '--format', '{{.Server.Version}}') -Capture)
if ($dockerVer.Code -ne 0) { throw 'Docker engine is not reachable - start Docker Desktop first' }
Write-Ok "docker engine $($dockerVer.Output.Trim())"

$py = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $py) { $py = (Get-Command python3 -ErrorAction SilentlyContinue) }
if (-not $py) { throw 'python is required to build the Node-RED flow' }
Write-Ok "python $((& $py.Source --version 2>&1) -replace 'Python ','')"

$cfg = Read-EnvFile $EnvPath
Write-Ok "project $DemoDir"

# ---------------------------------------------------------------------------
# 2. .env self-heal
# ---------------------------------------------------------------------------
Write-Step '2/10  .env paths and secrets'

# Absolute paths in .env break the moment the folder is renamed. Rewrite them
# to this checkout every run, so a renamed/moved build converges silently.
$wantedPaths = @{
    'FLOWS_PATH'           = ($FlowPath -replace '\\', '/')
    'NODE_RED_SOURCE_FLOW' = $FlowSrc
}
foreach ($k in $wantedPaths.Keys) {
    if ($VerifyOnly) {
        if ($cfg[$k] -ne $wantedPaths[$k]) { Write-Fail "$k points at '$($cfg[$k])' (expected $($wantedPaths[$k]))" }
        else { Write-Ok "$k correct" }
    } elseif (Set-EnvValue $EnvPath $k $wantedPaths[$k]) {
        Write-Change "$k -> $($wantedPaths[$k])"
    } else {
        Write-Ok "$k correct"
    }
}

# same for the planner-integration env file
$PlannerEnv = Join-Path $SandboxDir '.env.ai-fix'
if (Test-Path $PlannerEnv) {
    $pe = Read-EnvFile $PlannerEnv
    if ($pe['COMPOSE_PROJECT_NAME'] -and $pe['COMPOSE_PROJECT_NAME'] -ne $Project) {
        if (-not $VerifyOnly) { Set-EnvValue $PlannerEnv 'COMPOSE_PROJECT_NAME' $Project | Out-Null; Write-Change ".env.ai-fix COMPOSE_PROJECT_NAME -> $Project" }
    }
    if ($pe['NODE_RED_SOURCE_FLOW'] -and -not (Test-Path $pe['NODE_RED_SOURCE_FLOW'])) {
        if (-not $VerifyOnly) { Set-EnvValue $PlannerEnv 'NODE_RED_SOURCE_FLOW' $FlowSrc | Out-Null; Write-Change '.env.ai-fix NODE_RED_SOURCE_FLOW -> this build' }
    }
}

$cfg = Read-EnvFile $EnvPath

# Collect any missing Shopify credentials interactively (fresh clone / fresh .env).
if (-not $VerifyOnly) {
    Prompt-ShopifyCredentials -cfg $cfg -EnvPath $EnvPath
    $cfg = Read-EnvFile $EnvPath
}

$erpPort      = if ($cfg['ERPNEXT_PORT'])      { $cfg['ERPNEXT_PORT'] }      else { '8000' }
$nodeRedPort  = if ($cfg['NODE_RED_PORT'])     { $cfg['NODE_RED_PORT'] }     else { '1880' }
$plannerPort  = if ($cfg['SCHEDULER_PORT'])    { $cfg['SCHEDULER_PORT'] }    else { '3001' }
$ngrokApiPort = if ($cfg['NGROK_API_PORT'])    { $cfg['NGROK_API_PORT'] }    else { '4040' }
$siteName     = if ($cfg['SITE_NAME'])         { $cfg['SITE_NAME'] }         else { 'frontend' }
$shopifyStore = $cfg['SHOPIFY_STORE']
$shopifyVer   = if ($cfg['SHOPIFY_API_VERSION']) { $cfg['SHOPIFY_API_VERSION'] } else { '2026-04' }

if (-not $shopifyStore) { Write-Fail 'SHOPIFY_STORE missing from .env' }
if (-not $cfg['SHOPIFY_CLIENT_ID'] -or -not $cfg['SHOPIFY_CLIENT_SECRET']) {
    Write-Warn 'SHOPIFY_CLIENT_ID / SHOPIFY_CLIENT_SECRET missing - the Shopify token cannot be minted'
}

# ---------------------------------------------------------------------------
# 3. optional full rebuild
# ---------------------------------------------------------------------------
if ($Full) {
    Write-Step '3/10  full rebuild (delegating to up.ps1)'
    if ($VerifyOnly) { throw '-Full and -VerifyOnly are mutually exclusive' }
    $upArgs = @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $DemoDir 'up.ps1'))
    if ($Wipe) { $upArgs += '-Fresh' }
    Write-Info 'this takes 25-35 minutes and streams up.ps1 output'
    $rc = Invoke-Native -Exe 'powershell.exe' -Arguments $upArgs
    if ($rc -ne 0) { Write-Fail "up.ps1 exited $rc" } else { Write-Ok 'up.ps1 completed' }
}

# ---------------------------------------------------------------------------
# 4. containers
# ---------------------------------------------------------------------------
Write-Step '4/10  containers'

$running = (Invoke-Docker -Arguments @('ps', '--format', '{{.Names}}') -Capture).Output

if ($VerifyOnly) {
    foreach ($svc in $MandatoryServices) {
        $n = "$Project-$svc-1"
        if ($running -match [regex]::Escape($n)) { Write-Ok "$n running" } else { Write-Fail "$n not running" }
    }
} else {
    # bench and db hold irreplaceable state: the bench app tree lives in the
    # container's writable layer and the site DB is tmpfs. Recreating either of
    # them destroys the site, so a missing one is a -Full situation, not a
    # "start it again" one.
    foreach ($critical in @('bench', 'db')) {
        $cn = "$Project-$critical-1"
        if (-not $running -match [regex]::Escape($cn)) {
            $exists = (Invoke-Docker -Arguments @('ps', '-a', '--format', '{{.Names}}') -Capture).Output
            if ($exists -match [regex]::Escape($cn)) {
                Write-Info "$cn is stopped - starting it (the tmpfs site survives a stop only while the container exists)"
                Invoke-Docker -Arguments @('start', $cn) | Out-Null
                Write-Change "$cn started"
            } else {
                throw "$cn does not exist - its writable layer (the whole bench) is gone. Run: .\setup.ps1 -Full"
            }
        }
    }

    # Everything else is stateless enough to recreate individually. Creating one
    # service at a time keeps `docker compose create` from touching bench/db.
    $startList = @()
    foreach ($svc in $MandatoryServices) {
        $n = "$Project-$svc-1"
        if ($running -match [regex]::Escape($n)) { continue }
        $exists = (Invoke-Docker -Arguments @('ps', '-a', '--format', '{{.Names}}') -Capture).Output
        if ($exists -match [regex]::Escape($n)) { $startList += $n }
        else {
            Invoke-Compose @('create', $svc) | Out-Null
            $startList += $n
        }
    }
    if ($startList.Count -gt 0) {
        Invoke-Docker -Arguments (@('start') + $startList) | Out-Null
        Write-Change ("started: " + ($startList -join ', '))
    }

    $deadline = (Get-Date).AddSeconds(150)
    do {
        Start-Sleep -Seconds 3
        $running = (Invoke-Docker -Arguments @('ps', '--format', '{{.Names}}') -Capture).Output
    } while ((Get-Date) -lt $deadline -and @($MandatoryServices | Where-Object { $running -notmatch [regex]::Escape("$Project-$_-1") }).Count -gt 0)

    $stillDown = @($MandatoryServices | Where-Object { $running -notmatch [regex]::Escape("$Project-$_-1") })
    if ($stillDown.Count -eq 0) { Write-Ok 'all 5 services running' }
    else { Write-Fail ("not running: " + ($stillDown -join ', ')) }
}

if (Get-Process -Name 'ngrok' -ErrorAction SilentlyContinue) { Write-Ok 'ngrok agent process present' }

# ---------------------------------------------------------------------------
# 5. bench sanity
# ---------------------------------------------------------------------------
Write-Step '5/10  bench site'

$siteCheck = (Invoke-Bench "ls -d /home/frappe/frappe-bench/sites/$siteName 2>/dev/null" -Capture)
if ($siteCheck.Code -ne 0 -or -not $siteCheck.Output.Trim()) {
    Write-Fail "site '$siteName' is missing - the tmpfs DB was discarded; run with -Full"
} else {
    Write-Ok "site '$siteName' present"
    $apps = (Invoke-Bench 'cat /home/frappe/frappe-bench/sites/apps.txt' -Capture).Output
    foreach ($app in @('frappe', 'erpnext', 'barcode_shrdc', 'shopify', 'eu_einvoice')) {
        if ($apps -match "(?m)^\s*$([regex]::Escape($app))\s*$") { Write-Ok "app $app" } else { Write-Warn "app $app not installed" }
    }
    # frappe's logger needs this; a recreated container loses it
    $logs = (Invoke-BenchRoot 'test -d /home/frappe/logs && echo yes || echo no' -Capture).Output.Trim()
    if ($logs -ne 'yes') {
        if (-not $VerifyOnly) {
            Invoke-BenchRoot 'mkdir -p /home/frappe/logs && chown frappe:frappe /home/frappe/logs' | Out-Null
            Write-Change '/home/frappe/logs recreated'
        } else { Write-Fail '/home/frappe/logs missing' }
    }
    # NB: no quotes inside the command - PowerShell -> bash -lc strips them in a
    # way that silently turns the pattern into a non-match. grep -F is enough.
    $ssLine = (Invoke-BenchRoot "grep -F server_script_enabled /home/frappe/frappe-bench/sites/common_site_config.json" -Capture).Output
    if ($ssLine -match ':\s*1') {
        Write-Ok 'server_script_enabled=1'
    } elseif ($VerifyOnly) {
        Write-Fail 'server_script_enabled is not 1 - planner Job Card drags will only move the first operation'
    } else {
        Invoke-Bench "cd /home/frappe/frappe-bench && bench set-config -g server_script_enabled 1" | Out-Null
        Invoke-Bench "cd /home/frappe/frappe-bench && bench --site $siteName clear-cache" | Out-Null
        Write-Change 'server_script_enabled set to 1 (required for Job Card drags)'
    }
}

# ---------------------------------------------------------------------------
# 5b. background jobs: Frappe scheduler + worker
# ---------------------------------------------------------------------------
# The compose stack starts the bench container with `sleep infinity` and only
# `bench serve` gets started, so BOTH of these were missing. Consequence: no
# `all`/cron hook ever fires and no queued job ever executes - which is why
# Shopify orders stopped importing (shopify.retrieve_order.
# scheduled_retrieve_shopify_orders is an "all" hook).
#
# Also re-sync the Scheduled Job Type registry: those rows are normally seeded by
# `bench migrate` -> sync_jobs(). Without them the shopify hooks are not even
# schedulable, so starting the scheduler alone is not enough.
Write-Step '5b/10  background jobs (scheduler + worker)'

if ($siteCheck.Code -eq 0 -and $siteCheck.Output.Trim()) {
    $procList = (Invoke-Bench 'ps -eo args' -Capture).Output

    foreach ($job in @(
            @{ Match = 'frappe schedule'; Label = 'bench schedule'; Cmd = 'cd /home/frappe/frappe-bench && setsid nohup bench schedule > /tmp/bench-schedule.log 2>&1 &'; Why = 'no background/cron hook will ever fire' },
            @{ Match = 'frappe worker'; Label = 'bench worker'; Cmd = 'cd /home/frappe/frappe-bench && setsid nohup bench worker --queue short,default,long >> logs/worker.log 2>&1 &'; Why = 'queued jobs will never execute' }
        )) {
        if ($procList -match [regex]::Escape($job.Match)) {
            Write-Ok "$($job.Label) running"
        } elseif ($VerifyOnly) {
            Write-Fail "$($job.Label) is not running - $($job.Why)"
        } else {
            Invoke-Bench $job.Cmd | Out-Null
            Write-Change "started $($job.Label)"
        }
    }

    if (-not $VerifyOnly) {
        Invoke-Bench "cd /home/frappe/frappe-bench && bench --site $siteName execute frappe.core.doctype.scheduled_job_type.scheduled_job_type.sync_jobs" | Out-Null
        Write-Ok 'scheduled job registry synced from hooks'

        # Confirm the shopify hooks are actually schedulable now (they are absent
        # until sync_jobs runs, which is why starting the scheduler alone was not
        # enough). Done over REST to avoid nested shell quoting.
        $tokForCheck = (Read-EnvFile $EnvPath)['ERPNEXT_API_TOKEN']
        if ($tokForCheck) {
            $f = '[["method","like","shopify%"]]'
            $jr = Invoke-Api -Method GET -Uri "http://localhost:$erpPort/api/resource/Scheduled%20Job%20Type?filters=$([uri]::EscapeDataString($f))&fields=%5B%22method%22%5D&limit_page_length=0" `
                -Headers @{ Authorization = "token $tokForCheck" } -TimeoutSec 20
            if ($jr.Ok) {
                $n = @($jr.Data.data).Count
                if ($n -gt 0) { Write-Ok "$n shopify hooks are schedulable" }
                else { Write-Warn 'no shopify scheduled jobs registered - check sandbox/apps.txt' }
            }
        }
    }

    $ordSync = (Invoke-BenchRoot "grep -c shopify_order_sync_since /home/frappe/frappe-bench/sites/$siteName/site_config.json || true" -Capture).Output
    if ($ordSync -match '1') {
        Write-Ok 'Shopify order import has a created_at cutoff (history not bulk-imported)'
    } else {
        Write-Warn 'no shopify_order_sync_since cutoff - the next order sync will import the WHOLE order history'
    }
}

# ---------------------------------------------------------------------------
# 6. ERPNext API token (used by the Node-RED flow)
# ---------------------------------------------------------------------------
Write-Step '6/10  ERPNext API token'

# Set whenever a credential the flow bakes in changes, so step 8 redeploys it.
$flowDirty = $false

$erpToken = $cfg['ERPNEXT_API_TOKEN']
if (Test-ApiToken $erpToken) {
    Write-Ok 'token in .env is valid'
} elseif ($VerifyOnly) {
    Write-Fail 'token in .env is rejected (401)'
} else {
    Write-Info 'token rejected - rotating via generate_keys()'

    $mintModule = @'
import frappe
from frappe.core.doctype.user.user import generate_keys


def run(user="Administrator"):
	"""Rotate an API key using ERPNext's own generator.

	frappe.db.set_value writes api_secret as plaintext, but User.api_secret is a
	Password field, so authentication then compares a hash and always 401s.
	generate_keys() encrypts it the way the auth layer expects.
	"""
	frappe.set_user("Administrator")
	keys = generate_keys(user)
	frappe.db.commit()
	frappe.clear_cache(user=user)
	print("MARK_TOKEN %s:%s" % (keys["api_key"], keys["api_secret"]))
'@
    $tmp = Join-Path $env:TEMP '_setup_mint.py'
    [System.IO.File]::WriteAllText($tmp, $mintModule, (New-Object System.Text.UTF8Encoding($false)))
    $dest = '/home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc/_aifix_setup_mint.py'
    Invoke-Docker -Arguments @('cp', $tmp, "${BenchName}:$dest") -Capture | Out-Null
    $mintOut = (Invoke-Bench "cd /home/frappe/frappe-bench && bench --site $siteName execute barcode_shrdc._aifix_setup_mint.run" -Capture).Output
    Invoke-Bench "rm -f $dest" -Capture | Out-Null

    $m = [regex]::Match($mintOut, 'MARK_TOKEN\s+([0-9A-Za-z]+:[0-9A-Za-z]+)')
    if ($m.Success) {
        $erpToken = $m.Groups[1].Value
        Set-EnvValue $EnvPath 'ERPNEXT_API_TOKEN' $erpToken | Out-Null
        $cfg['ERPNEXT_API_TOKEN'] = $erpToken
        $flowDirty = $true   # the flow bakes this token too
        Write-Change "ERPNext API token rotated ($($erpToken.Split(':')[0])...)"
        if (Test-ApiToken $erpToken) { Write-Ok 'new token authenticates' } else { Write-Fail 'new token still rejected' }
    } else {
        Write-Fail "could not mint an API token: $($mintOut.Trim())"
    }
}

# ---------------------------------------------------------------------------
# 7. Shopify 24 h token
# ---------------------------------------------------------------------------
Write-Step '7/10  Shopify Admin API token'

$shopifyToken = $cfg['SHOPIFY_ACCESS_TOKEN']
$shopifyValid = $false
if ($shopifyToken) { $shopifyValid = Test-ShopifyToken $shopifyToken $shopifyStore $shopifyVer }

if ($SkipShopify -and $shopifyToken) {
    Write-Ok 'kept the existing SHOPIFY_ACCESS_TOKEN (-SkipShopify)'
} elseif ($VerifyOnly) {
    if (-not $shopifyToken) { Write-Fail 'SHOPIFY_ACCESS_TOKEN missing' }
    elseif ($shopifyValid) { Write-Ok 'token valid against the Shopify Admin API' }
    else { Write-Fail 'SHOPIFY_ACCESS_TOKEN is expired or rejected (401)' }
} elseif ($shopifyValid) {
    # Minting unconditionally every run would rotate the token in .env while the
    # deployed flow still carries the previous one, i.e. silent drift. Only mint
    # when the live token is actually dead.
    Write-Ok 'token still valid - not re-minted'
} elseif (-not $cfg['SHOPIFY_CLIENT_ID'] -or -not $cfg['SHOPIFY_CLIENT_SECRET']) {
    Write-Warn 'client credentials missing - keeping the existing token'
} else {
    try {
        $body = @{
            client_id     = $cfg['SHOPIFY_CLIENT_ID']
            client_secret = $cfg['SHOPIFY_CLIENT_SECRET']
            grant_type    = 'client_credentials'
        } | ConvertTo-Json
        $resp = Invoke-RestMethod -Uri "https://$shopifyStore/admin/oauth/access_token" -Method Post `
            -ContentType 'application/json' -Body $body -TimeoutSec 45
        if ($resp.access_token) {
            $shopifyToken = $resp.access_token
            Set-EnvValue $EnvPath 'SHOPIFY_ACCESS_TOKEN' $shopifyToken | Out-Null
            $cfg['SHOPIFY_ACCESS_TOKEN'] = $shopifyToken
            $flowDirty = $true   # the flow bakes this token, so it must be rebuilt
            $hours = [math]::Round($resp.expires_in / 3600, 1)
            $scopeCount = ($resp.scope -split ',').Count
            Write-Change "Shopify token minted: $($shopifyToken.Substring(0,12))... valid ${hours}h, $scopeCount scopes"
        } else {
            Write-Fail 'Shopify returned no access_token'
        }
    } catch {
        Write-Fail "Shopify token mint failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 8. Node-RED flow + mount
# ---------------------------------------------------------------------------
Write-Step '8/10  Node-RED flow'

# The flow is only useful if its file is actually mounted: the container binds
# FLOWS_PATH, and when that path is stale Docker leaves /data/flows.json
# missing while a previously-loaded flow keeps running from memory. It then
# vanishes on the next restart.
$mountOk = $false
$stat = (Invoke-Docker -Arguments @('exec', $NodeRedName, 'bash', '-lc', 'test -s /data/flows.json && echo yes || echo no') -Capture)
if ($stat.Output -match 'yes') { $mountOk = $true }

$rebuildFlow = $ForceFlow -or (-not $mountOk) -or $flowDirty
if ($VerifyOnly) {
    if ($mountOk) { Write-Ok 'flows.json mounted in the container' } else { Write-Fail '/data/flows.json is not mounted (stale FLOWS_PATH) - the flow dies on restart' }
    try {
        $live = Invoke-RestMethod -Uri "http://localhost:$nodeRedPort/flows" -TimeoutSec 15
        Write-Ok "flow running: $($live.Count) nodes"
    } catch { Write-Fail 'Node-RED /flows not readable' }
} else {
    # build first, so a rebuild never leaves the container with an empty flow
    if ($rebuildFlow) {
        if (-not $shopifyToken) { Write-Warn 'no Shopify token - the flow will bake an empty value' }
        & $py.Source $Builder --src $FlowSrc --out $FlowPath `
            --erpnext-url 'http://bench:8000' --erpnext-token $erpToken `
            --shopify-store $shopifyStore --shopify-version $shopifyVer `
            --shopify-token $shopifyToken --site $siteName | Out-Null

        if ($LASTEXITCODE -ne 0) { Write-Fail "flow builder exited $LASTEXITCODE" }
        elseif (-not (Test-Path $FlowPath)) { Write-Fail 'flow builder produced no file' }
        else {
            $check = & $py.Source $FlowCheck $FlowPath 2>&1
            $nodeCount = 0
            $null = ($check -join "`n") -match 'nodes\s+:\s+(\d+)'
            if ($Matches) { $nodeCount = [int]$Matches[1] }
            if ($nodeCount -lt 40) {
                Write-Fail "built flow has only $nodeCount nodes - refusing to deploy"
            } else {
                Write-Ok "flow rebuilt ($nodeCount nodes, 3 endpoints)"
                if (-not $mountOk) {
                    Write-Info 'recreating node-red so the container binds the real path'

                    # Stage the webhook wiring script for later, then recreate.
                    Invoke-Docker -Arguments @('rm', '-f', $NodeRedName) -Capture | Out-Null
                    Invoke-Compose @('create', 'node-red') | Out-Null
                    Invoke-Docker -Arguments @('start', $NodeRedName) | Out-Null
                    $deadline = (Get-Date).AddSeconds(90)
                    do {
                        Start-Sleep -Seconds 3
                        $ready = (Get-HttpStatus "http://localhost:$nodeRedPort/")
                    } while ((Get-Date) -lt $deadline -and $ready -ne 200)
                    Write-Change 'node-red recreated with a correct flows.json mount'
                } else {
                    Invoke-Docker -Arguments @('restart', $NodeRedName) -Capture | Out-Null
                    $deadline = (Get-Date).AddSeconds(90)
                    do {
                        Start-Sleep -Seconds 3
                        $ready = (Get-HttpStatus "http://localhost:$nodeRedPort/")
                    } while ((Get-Date) -lt $deadline -and $ready -ne 200)
                    Write-Change 'node-red restarted with the rebuilt flow'
                }
            }
        }
    } else {
        Write-Ok 'flow file already mounted (use -ForceFlow to rebuild)'
    }
}

# ---------------------------------------------------------------------------
# 9. tunnel + webhooks
# ---------------------------------------------------------------------------
Write-Step '9/10  ngrok tunnel and ERPNext webhooks'

function Get-PublicUrl {
    foreach ($port in @($ngrokApiPort, 4040) | Select-Object -Unique) {
        try {
            $t = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/tunnels" -TimeoutSec 4
            $u = ($t.tunnels | Where-Object { $_.public_url } | Select-Object -First 1).public_url
            if ($u) { return $u }
        } catch { }
    }
    return $null
}

$publicUrl = Get-PublicUrl
if (-not $publicUrl -and -not $VerifyOnly) {
    $ngrokExe = (Get-Command ngrok -ErrorAction SilentlyContinue).Source
    if (-not $ngrokExe) {
        $ngrokExe = Get-ChildItem 'C:\Program Files\WindowsApps\ngrok.ngrok_*' -Filter 'ngrok.exe' -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ($ngrokExe) {
        $cacheDir = Join-Path $DemoDir '.cache'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        Write-Info "starting ngrok http localhost:$nodeRedPort"
        Start-Process -FilePath $ngrokExe -ArgumentList @('http', $nodeRedPort, '--log', 'stdout') `
            -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $cacheDir 'ngrok.log') `
            -RedirectStandardError (Join-Path $cacheDir 'ngrok.err.log') | Out-Null
        $deadline = (Get-Date).AddSeconds(60)
        do { Start-Sleep -Seconds 4; $publicUrl = Get-PublicUrl } while ((Get-Date) -lt $deadline -and -not $publicUrl)
        if ($publicUrl) { Write-Change "tunnel started: $publicUrl" }
    } else {
        Write-Fail 'no ngrok binary found'
    }
}

if (-not $publicUrl) {
    Write-Fail 'no ngrok tunnel - webhooks cannot be pointed anywhere'
} else {
    Write-Ok "tunnel $publicUrl -> localhost:$nodeRedPort"

    $hooks = @(
        @{ Doctype = 'Delivery Note';        Event = 'on_submit'; Path = '/delivery-note' },
        @{ Doctype = 'Stock Entry';          Event = 'on_submit'; Path = '/stock-entry' },
        @{ Doctype = 'Stock Reconciliation'; Event = 'on_submit'; Path = '/stock-recon' }
    )

    # Read current state with the (now valid) token.
    $current = $null
    if ($erpToken) {
        try {
            $current = (Invoke-RestMethod -Uri "http://localhost:$erpPort/api/resource/Webhook?fields=%5B%22name%22%2C%22webhook_doctype%22%2C%22webhook_docevent%22%2C%22request_url%22%2C%22enabled%22%5D&limit_page_length=50" `
                -Headers @{ Authorization = "token $erpToken" } -TimeoutSec 25).data
        } catch { }
    }

    $needWire = $false
    if (-not $current) { $needWire = $true }
    else {
        foreach ($h in $hooks) {
            $row = $current | Where-Object { $_.webhook_doctype -eq $h.Doctype -and $_.webhook_docevent -eq $h.Event } | Select-Object -First 1
            if (-not $row) { $needWire = $true; break }
            if ($row.request_url -ne "$publicUrl$($h.Path)" -or -not $row.enabled) { $needWire = $true; break }
        }
    }

    if ($VerifyOnly) {
        if (-not $current) { Write-Fail 'webhook records unreadable' }
        else {
            foreach ($h in $hooks) {
                $row = $current | Where-Object { $_.webhook_doctype -eq $h.Doctype -and $_.webhook_docevent -eq $h.Event } | Select-Object -First 1
                if (-not $row) { Write-Fail "webhook missing: $($h.Doctype)" }
                elseif ($row.request_url -ne "$publicUrl$($h.Path)") { Write-Fail "webhook $($h.Doctype) -> $($row.request_url) (stale)" }
                elseif (-not $row.enabled) { Write-Fail "webhook $($h.Doctype) disabled" }
                else { Write-Ok "webhook $($h.Doctype) -> $($h.Path)" }
            }
        }
    } elseif ($needWire) {
        $tmpScript = '/tmp/scripts/ai-fix-wire-webhooks.sh'
        Invoke-BenchRoot 'mkdir -p /tmp/scripts' | Out-Null
        Invoke-Docker -Arguments @('cp', $WhScript, "${BenchName}:$tmpScript") -Capture | Out-Null
        Invoke-BenchRoot "chown frappe:frappe $tmpScript" | Out-Null
        $wire = (Invoke-Bench "SITE_NAME=$siteName bash $tmpScript $publicUrl" -Capture).Output
        if ($wire -match 'webhooks configured and enabled') {
            Write-Change "3 webhooks pointed at $publicUrl"
        } else {
            Write-Fail "webhook wiring failed: $($wire.Trim())"
        }
    } else {
        Write-Ok '3 webhooks already current'
    }

    foreach ($h in $hooks) {
        $code = Get-HttpStatus "$publicUrl$($h.Path)" -Method 'POST' -Body '{}' `
            -Headers @{ 'ngrok-skip-browser-warning' = '1' }
        if ($code -eq 200) { Write-Ok "tunnel POST $($h.Path) -> 200" }
        else { Write-Fail "tunnel POST $($h.Path) -> $code" }
    }
}

# ---------------------------------------------------------------------------
# 10. verify
# ---------------------------------------------------------------------------
Write-Step '10/10  verification'

$erpPing = Get-HttpStatus "http://localhost:$erpPort/api/method/ping"
if ($erpPing -eq 200) { Write-Ok "ERPNext   http://localhost:$erpPort" } else { Write-Fail "ERPNext -> $erpPing" }

$plannerOk = $false
try {
    $h = Invoke-RestMethod "http://localhost:$plannerPort/api/health" -TimeoutSec 10
    $plannerOk = [bool]$h.status
} catch { $plannerOk = $false }
if (-not $plannerOk) { $plannerOk = ((Get-HttpStatus "http://localhost:$plannerPort/api/health") -eq 200) }
if ($plannerOk) { Write-Ok "Planner   http://localhost:$plannerPort" } else { Write-Fail "Planner on :$plannerPort not healthy" }

$nrRoot = Get-HttpStatus "http://localhost:$nodeRedPort/"
if ($nrRoot -eq 200) { Write-Ok "Node-RED  http://localhost:$nodeRedPort" } else { Write-Fail "Node-RED -> $nrRoot" }

try {
    $flow = Invoke-RestMethod "http://localhost:$nodeRedPort/flows" -TimeoutSec 15
    $nrIn = @($flow | Where-Object { $_.type -eq 'http in' }).Count
    if ($flow.Count -ge 40 -and $nrIn -ge 3) { Write-Ok "flow deployed: $($flow.Count) nodes, $nrIn http endpoints" }
    else { Write-Fail "flow looks incomplete: $($flow.Count) nodes, $nrIn endpoints" }
} catch { Write-Fail 'cannot read /flows' }

foreach ($p in @('/delivery-note', '/stock-entry', '/stock-recon')) {
    $c = Get-HttpStatus "http://localhost:$nodeRedPort$p" -Method 'POST' -Body '{}'
    if ($c -eq 200) { Write-Ok "local POST $p -> 200" } else { Write-Fail "local POST $p -> $c" }
}

if ($erpToken) {
    if (Test-ApiToken $erpToken) { Write-Ok 'ERPNext API token authenticates' } else { Write-Fail 'ERPNext API token rejected' }
}

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 74) -ForegroundColor $(if ($script:Issues.Count -eq 0) { 'Green' } else { 'Red' })
if ($script:Issues.Count -eq 0) {
    Write-Host '  SETUP COMPLETE - all checks pass' -ForegroundColor Green
} else {
    Write-Host "  SETUP INCOMPLETE - $($script:Issues.Count) problem(s)" -ForegroundColor Red
}
Write-Host ('=' * 74) -ForegroundColor $(if ($script:Issues.Count -eq 0) { 'Green' } else { 'Red' })
Write-Host "  ERPNext   : http://localhost:$erpPort   (Administrator / admin, site '$siteName')"
Write-Host "  Planner   : http://localhost:$plannerPort"
Write-Host "  Node-RED  : http://localhost:$nodeRedPort"
Write-Host "  ngrok API : http://localhost:$ngrokApiPort"
if ($publicUrl) { Write-Host "  Public    : $publicUrl" }
if ($script:Fixed.Count -gt 0) {
    Write-Host ''
    Write-Host '  changes made:'
    $script:Fixed | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
}
if ($script:Issues.Count -gt 0) {
    Write-Host ''
    Write-Host '  outstanding:'
    $script:Issues | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
}
Write-Host ''

if ($script:Issues.Count -gt 0) { exit 1 }
exit 0
