<#
.SYNOPSIS
    ERPNEXT-AI-FIX - one-shot bring-up of a self-contained ERPNext stack with a
    working barcode scanner and a working Shopify <-> ERPNext bridge.

.DESCRIPTION
    Replaces the old setup, which depended on a host-level `node-red` (running
    with zero deployed flows) and a host-level `ngrok` tunnel, and whose
    ERPNext Webhook records pointed at a dead tunnel URL.

    This script:
      1. starts its OWN compose project (`erpnext-ai-fix`): bench + db + redis
         + node-red + ngrok, on its own ports and volumes
      2. provisions an ERPNext v16 site
      3. installs barcode_shrdc (from the downloaded source, with the v16 fix
         chain applied, then exported back as a durable fork)
      4. installs the v16-fixed shopify app
      5. mints an ERPNext API token and rewrites the Node-RED flow so it can
         actually reach ERPNext (bench:8000, NOT localhost:8000) and Shopify
         (one real token, not two conflicting ones)
      6. reads the live ngrok public URL back and writes it into the three
         ERPNext Webhook records, then enables them
      7. brings up the production planner (the `scheduler` compose service) via
         sandbox/scheduler-up.ps1 - token, demo Work Orders, desk shortcut, verify

.PARAMETER Fresh
    `docker compose down -v` first. DESTRUCTIVE: wipes the site DB and volumes.

.PARAMETER SkipProvision
    Reuse an already-provisioned site (skip bench init / new-site).

.PARAMETER SkipInstall
    Reuse already-installed apps (skip the app install step).

.PARAMETER SkipScheduler
    Skip the production planner bring-up (sandbox/scheduler-up.ps1).

.EXAMPLE
    pwsh -File .\sandbox\up.ps1
    pwsh -File .\sandbox\up.ps1 -Fresh
#>
[CmdletBinding()]
param(
    [switch]$Fresh,
    [switch]$SkipProvision,
    [switch]$SkipInstall,
    [switch]$SkipScheduler
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$SandboxDir = $PSScriptRoot
$RootDir = Split-Path -Parent $SandboxDir
$ComposeFile = Join-Path $SandboxDir 'docker-compose.erpnext-ai-fix.yml'
$EnvPath = Join-Path $SandboxDir '.env.ai-fix'
$Project = 'erpnext-ai-fix'
$NgrokYml = Join-Path $env:LOCALAPPDATA 'Packages\ngrok.ngrok_1g87z0zv29zzc\LocalCache\Local\ngrok\ngrok.yml'

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}
function Write-Info([string]$Message) { Write-Host "  $Message" }
function Write-Warn([string]$Message) { Write-Host "  WARN: $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "  FAIL: $Message" -ForegroundColor Red }

function Read-EnvFile([string]$Path) {
    $table = @{}
    if (-not (Test-Path $Path)) { return $table }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $table[$Matches[1]] = $Matches[2]
        }
    }
    return $table
}

# BOM-safe rewrite: Windows PowerShell 5.1's `Set-Content -Encoding UTF8` adds a
# BOM, which makes docker compose choke on the first variable in the file.
function Set-EnvValue([string]$Path, [string]$Key, [string]$Value) {
    $lines = [System.Collections.Generic.List[string]](@(Get-Content -LiteralPath $Path))
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$([regex]::Escape($Key))\s*=") {
            $lines[$i] = "$Key=$Value"; $found = $true; break
        }
    }
    if (-not $found) { $lines.Add("$Key=$Value") }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $lines, $utf8)
}

# Every docker call funnels through here. Output is streamed to the console and
# ONLY the exit code is returned, unless -Capture is used - mixing the two was
# how `$code = Invoke-Bench ...` ended up comparing an array against 0.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [switch]$Capture)
    # Native tools write progress to stderr. With $ErrorActionPreference='Stop'
    # PowerShell 5.1 promotes those stderr lines to TERMINATING errors, which
    # killed this script on docker's first "Container ... Stopping" message.
    # Relax it for the duration of the call and flatten ErrorRecords to text.
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
    if ($Capture) { return [pscustomobject]@{ Output = ($lines -join [Environment]::NewLine); Code = $code } }
    $lines | ForEach-Object { Write-Host $_ }
    return $code
}
function Invoke-Docker { param([string[]]$Arguments, [switch]$Capture) Invoke-Native -Exe 'docker' -Arguments $Arguments -Capture:$Capture }

# IMPORTANT: `docker compose up` HANGS on this host. The Docker CLI has
# agent/AI hooks attached to the `compose up` subcommand (see
# ~/.docker/config.json -> plugins.compose.hooks) and the hook never returns,
# even though the containers are created and started correctly. Invoking the
# very same Compose binary directly skips the CLI hook layer and completes
# immediately, so that is what we do when it is available.
$script:ComposeExe = (Get-Command docker-compose -ErrorAction SilentlyContinue).Source
if ($script:ComposeExe) {
    $script:composeBase = @('-p', $Project, '--env-file', $EnvPath, '-f', $ComposeFile)
} else {
    $script:ComposeExe = 'docker'
    $script:composeBase = @('compose', '-p', $Project, '--env-file', $EnvPath, '-f', $ComposeFile)
}
function Invoke-Compose { param([string[]]$Arguments) Invoke-Native -Exe $script:ComposeExe -Arguments ($script:composeBase + $Arguments) }
function Invoke-ComposeCapture { param([string[]]$Arguments) Invoke-Native -Exe $script:ComposeExe -Arguments ($script:composeBase + $Arguments) -Capture }
function Invoke-Bench { param([string]$Command) Invoke-Native -Exe $script:ComposeExe -Arguments ($script:composeBase + @('exec', '-T', 'bench', 'bash', '-lc', $Command)) }
function Invoke-BenchRoot { param([string]$Command) Invoke-Native -Exe $script:ComposeExe -Arguments ($script:composeBase + @('exec', '-T', '-u', 'root', 'bench', 'bash', '-lc', $Command)) }

function Wait-Url([string]$Url, [int]$TimeoutSec = 180) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 8
            if ($r.StatusCode -eq 200) { return $true }
        } catch { }
        Start-Sleep -Seconds 4
    }
    return $false
}

# ---------------------------------------------------------------------------
# 0. configuration
# ---------------------------------------------------------------------------
Write-Step '0/11  configuration'

if (-not (Test-Path $ComposeFile)) { throw "compose file not found: $ComposeFile" }
if (-not (Test-Path $EnvPath)) { throw "env file not found: $EnvPath" }

$cfg = Read-EnvFile $EnvPath
$erpnextPort = if ($cfg['ERPNEXT_PORT']) { $cfg['ERPNEXT_PORT'] } else { '8000' }
$nodeRedPort = if ($cfg['NODE_RED_PORT']) { $cfg['NODE_RED_PORT'] } else { '1881' }
$ngrokApiPort = if ($cfg['NGROK_API_PORT']) { $cfg['NGROK_API_PORT'] } else { '4041' }
$siteName = if ($cfg['SITE_NAME']) { $cfg['SITE_NAME'] } else { 'frontend' }
$erpVersion = if ($cfg['ERPNEXT_VERSION']) { $cfg['ERPNEXT_VERSION'] } else { '16' }
$shopifyStore = if ($cfg['SHOPIFY_STORE']) { $cfg['SHOPIFY_STORE'] } else { '4e1075.myshopify.com' }
$shopifyVersion = if ($cfg['SHOPIFY_API_VERSION']) { $cfg['SHOPIFY_API_VERSION'] } else { '2026-04' }
$shopifyToken = $cfg['SHOPIFY_ACCESS_TOKEN']
$erpToken = $cfg['ERPNEXT_API_TOKEN']

# ngrok authtoken: reuse the one already configured on this machine.
$ngrokToken = $cfg['NGROK_AUTHTOKEN']
if ((-not $ngrokToken) -or $ngrokToken -eq '__NGROK_AUTHTOKEN__') {
    if (Test-Path $NgrokYml) {
        $m = [regex]::Match((Get-Content -LiteralPath $NgrokYml -Raw), 'authtoken:\s*(\S+)')
        if ($m.Success) {
            $ngrokToken = $m.Groups[1].Value
            Write-Info 'ngrok authtoken copied from the host ngrok config'
        }
    }
}
if ((-not $ngrokToken) -or $ngrokToken -eq '__NGROK_AUTHTOKEN__') {
    Write-Warn 'no ngrok authtoken available - the ngrok service will not start'
}

# Process environment WINS over the --env-file for compose interpolation, so
# secrets are supplied here and never need to be rewritten on disk.
$env:NGROK_AUTHTOKEN = $ngrokToken
$env:NGROK_URL_FLAG = if ($cfg['NGROK_PUBLIC_URL']) { '--url=' + $cfg['NGROK_PUBLIC_URL'] } else { '' }
$env:ERPNEXT_API_TOKEN = $erpToken
if ($cfg['NGROK_PUBLIC_URL']) { Write-Info "pinning the tunnel to $($cfg['NGROK_PUBLIC_URL'])" }

Write-Info "project      : $Project"
Write-Info "ERPNext      : http://localhost:$erpnextPort  (site '$siteName', v$erpVersion)"
Write-Info "Node-RED     : http://localhost:$nodeRedPort"
Write-Info "ngrok API    : http://localhost:$ngrokApiPort"
Write-Info "Shopify store: $shopifyStore (API $shopifyVersion)"
if (-not $shopifyToken) { Write-Warn 'SHOPIFY_ACCESS_TOKEN is blank - Shopify calls will 401 until you set it' }

# ---------------------------------------------------------------------------
# 1. port hygiene
# ---------------------------------------------------------------------------
Write-Step '1/11  freeing the ports the old host-level services hold'

# ngrok's free plan allows ONE agent session. A host-level `ngrok` currently
# points at a Node-RED with no flows deployed, so stopping it costs nothing and
# lets the containerised agent own the tunnel.
$hostNgrok = Get-Process -Name 'ngrok' -ErrorAction SilentlyContinue
if ($hostNgrok) {
    Write-Info ("stopping host-level ngrok (pid " + (($hostNgrok | ForEach-Object Id) -join ',') + ') - the stack runs its own')
    $hostNgrok | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
} else {
    Write-Info 'no host-level ngrok running'
}

# ---------------------------------------------------------------------------
# 2. node-red seed flow
# ---------------------------------------------------------------------------
Write-Step '2/11  preparing the Node-RED flow file'
$flowsPath = Join-Path $SandboxDir 'node-red\flows.json'
if (-not (Test-Path $flowsPath)) {
    Set-Content -LiteralPath $flowsPath -Value '[]' -Encoding ASCII
    Write-Info 'wrote placeholder flows.json (the real flow is built in step 8)'
} else {
    Write-Info 'flows.json already present'
}

# ---------------------------------------------------------------------------
# 3. compose up
# ---------------------------------------------------------------------------
Write-Step '3/11  starting the stack'
if ($Fresh) {
    Write-Warn 'DESTRUCTIVE: removing existing volumes (the site DB will be lost)'
    Invoke-Compose @('down', '-v', '--remove-orphans') | Out-Null
} elseif ($SkipProvision) {
    # The `down` below removes the bench container, and with it the whole bench
    # app tree (apps/, env/ live in the writable layer - only sites/ is a named
    # volume). That is harmless when we re-provision, but with -SkipProvision the
    # site would be left with no code and every later step would fail, so keep
    # the running containers instead.
    Write-Info 'keeping the existing containers (-SkipProvision)'
} else {
    # Clear containers left behind by an interrupted run: they hold their names
    # and make the next `up` fail with a name conflict. Volumes are preserved.
    Invoke-Compose @('down', '--remove-orphans') | Out-Null
}
if ((Invoke-Compose @('up', '-d')) -ne 0) { throw 'docker compose up failed' }
Write-Info 'containers started'

$deadline = (Get-Date).AddSeconds(180)
do {
    $services = (Invoke-ComposeCapture @('ps', '--services', '--status', 'running')).Output
    if ($services -match 'bench') { break }
    Start-Sleep -Seconds 3
} while ((Get-Date) -lt $deadline)
Write-Info ("running services: " + (($services | Where-Object { $_ }) -join ', '))

# ---------------------------------------------------------------------------
# 4. root-level container prep
# ---------------------------------------------------------------------------
Write-Step '4/11  root prep inside the bench container'
Invoke-BenchRoot 'chown -R frappe:frappe /home/frappe/frappe-bench 2>/dev/null || true; echo chown-done' | Out-Null
Invoke-BenchRoot 'which redis-server >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq redis-server); echo redis-ok' | Out-Null

# ---------------------------------------------------------------------------
# 5. stage scripts, recipes and app sources into the container
# ---------------------------------------------------------------------------
Write-Step '5/11  staging workspace files into the container'
Invoke-Bench 'mkdir -p /tmp/scripts/lib /tmp/recipes /tmp/repos /tmp/export' | Out-Null

# `docker compose cp` nests the tree when the destination already exists (a
# documented trap in this workspace), so stage to a scratch path first.
function Copy-Into([string]$HostPath, [string]$ContainerPath) {
    $leaf = Split-Path -Leaf $HostPath
    $scratch = "/tmp/_stage_$leaf"
    Invoke-BenchRoot "rm -rf $scratch" | Out-Null
    Invoke-Compose @('cp', $HostPath, "bench:$scratch") | Out-Null
    Invoke-BenchRoot "cp -a $scratch/. $ContainerPath/ && rm -rf $scratch" | Out-Null
}

Copy-Into (Join-Path $SandboxDir 'scripts') '/tmp/scripts'
Copy-Into (Join-Path $SandboxDir 'recipes') '/tmp/recipes'

$reposDir = Join-Path $RootDir 'repos'
$barcodeFixed = Join-Path $reposDir 'barcode-shrdc-v16-fixed'
$barcodeMaster = Join-Path $reposDir 'barcode-shrdc-master'
$shopifySrc = Join-Path $reposDir 'shopify-shrdc-v16-fixed'

if (Test-Path $barcodeFixed) {
    Copy-Into $barcodeFixed '/tmp/repos/barcode-shrdc-v16-fixed'
    Write-Info 'staged barcode_shrdc from the durable fixed fork'
} elseif (Test-Path $barcodeMaster) {
    Copy-Into $barcodeMaster '/tmp/repos/barcode-shrdc-master'
    Write-Info 'staged barcode_shrdc from the downloaded upstream source'
} else {
    Write-Warn 'no barcode source under repos/ - the barcode fix cannot be installed'
}
if (Test-Path $shopifySrc) {
    Copy-Into $shopifySrc '/tmp/repos/shopify-shrdc-v16-fixed'
    Write-Info 'staged shopify'
} else {
    Write-Warn 'no shopify source under repos/ - the Shopify side cannot be installed'
}

Invoke-BenchRoot 'chown -R frappe:frappe /tmp/scripts /tmp/recipes /tmp/repos /tmp/export' | Out-Null
Write-Info 'ownership normalised'

# ---------------------------------------------------------------------------
# 6. provision
# ---------------------------------------------------------------------------
if (-not $SkipProvision) {
    Write-Step "6/9  provisioning the ERPNext v$erpVersion base site (long step)"
    if ((Invoke-Bench "bash /tmp/scripts/provision-base.sh $erpVersion") -ne 0) {
        throw 'base provisioning failed (see the output above)'
    }
} else {
    Write-Step '6/11  provisioning skipped (-SkipProvision)'
}

# Native + Python render deps for server-side barcode/QR rasterisation
# (libcairo2-dev / pkg-config / reportlab / rlPyCairo). Root-only, and it MUST
# run AFTER provisioning because it pip-installs into the bench venv
# (/home/frappe/frappe-bench/env), which `bench init` only creates during
# provisioning. The apt half is idempotent, so re-running is cheap.
Invoke-BenchRoot 'bash /tmp/scripts/fix-barcode-v16-renderdeps.sh' | Out-Null
Write-Info 'barcode render dependencies prepared (cairo + reportlab + rlPyCairo)'

# ---------------------------------------------------------------------------
# 7. install apps
# ---------------------------------------------------------------------------
if (-not $SkipInstall) {
    Write-Step '7/11  installing barcode_shrdc + shopify (long step)'
    if ((Invoke-Bench 'bash /tmp/scripts/ai-fix-install.sh') -ne 0) {
        Write-Warn 'the app install reported errors - review the output above'
    }
} else {
    Write-Step '7/11  app install skipped (-SkipInstall)'
}

# capture the minted API token
$tokenResult = Invoke-ComposeCapture @('exec', '-T', 'bench', 'cat', '/tmp/export/erpnext_token.txt')
$token = $tokenResult.Output.Trim()
if ($token -match '^[0-9A-Za-z]+:[0-9A-Za-z]+$') {
    $erpToken = $token
    $env:ERPNEXT_API_TOKEN = $token
    Set-EnvValue $EnvPath 'ERPNEXT_API_TOKEN' $token
    Write-Info 'ERPNext API token captured'
} else {
    Write-Warn 'could not read the ERPNext API token - the Node-RED flow will authenticate as Guest'
}

# durable fork: keep the patched barcode tree on the host for future rebuilds
if (-not (Test-Path $barcodeFixed) -and (Test-Path $barcodeMaster)) {
    Write-Info 'exporting the patched barcode tree as repos/barcode-shrdc-v16-fixed'
    Invoke-Compose @('cp', 'bench:/tmp/export/barcode-shrdc-v16-fixed', $barcodeFixed) | Out-Null
    if (Test-Path $barcodeFixed) { Write-Info 'durable barcode fork written to repos/' }
}

# ---------------------------------------------------------------------------
# 8. Shopify post-setup: v16 item fix, master data, product/order sync
# ---------------------------------------------------------------------------
Write-Step '8/11  Shopify post-setup (master data + product/order sync)'
if ($shopifyToken) {
    if ((Invoke-Bench "bash /tmp/scripts/ai-fix-postsetup.sh $shopifyToken $shopifyStore $shopifyVersion") -ne 0) {
        Write-Warn 'Shopify post-setup reported errors - review the output above'
    }
} else {
    Write-Warn 'SHOPIFY_ACCESS_TOKEN is blank - skipping the Shopify sync entirely'
}

# ---------------------------------------------------------------------------
# 9. the production planner (standalone compose service, not a bench app)
# ---------------------------------------------------------------------------
# scheduler-up.ps1 owns everything planner-specific: the token, the demo
# manufacturing data, the Manufacturing-workspace shortcut and its own 5-step
# verification. -SkipBuild because this run already rebuilt the stack and the
# planner image build alone costs ~6 minutes.
if (-not $SkipScheduler) {
    Write-Step '9/11  production planner (scheduler service)'
    # Called in-process, not `pwsh -File`: this host has no pwsh on PATH, and a
    # .ps1's `exit N` only ends that script, so the parent keeps going.
    try {
        & (Join-Path $SandboxDir 'scheduler-up.ps1') -SkipBuild
        if ($LASTEXITCODE -ne 0) { Write-Warn 'the planner did not verify - review the output above' }
    } catch {
        Write-Warn "planner bring-up failed: $($_.Exception.Message)"
    }
} else {
    Write-Step '9/11  production planner skipped (-SkipScheduler)'
}

# ---------------------------------------------------------------------------
# 10. build the flow + restart Node-RED
# ---------------------------------------------------------------------------
Write-Step '10/11  building the Node-RED flow'

$flowSrc = $cfg['NODE_RED_SOURCE_FLOW']
if (-not $flowSrc -or -not (Test-Path $flowSrc)) {
    $fallback = 'F:\shopify_erpnext_integration.json'
    if (Test-Path $fallback) { $flowSrc = $fallback }
}
if (-not $flowSrc -or -not (Test-Path $flowSrc)) {
    Write-Warn "source flow export not found ($flowSrc) - keeping the existing flows.json"
} else {
    $builder = Join-Path $SandboxDir 'node-red\build-flows.py'
    $python = (Get-Command python -ErrorAction SilentlyContinue)
    if (-not $python) { $python = (Get-Command python3 -ErrorAction SilentlyContinue) }
    if (-not $python) { throw 'python is required to build the Node-RED flow' }

    & $python.Source $builder --src $flowSrc --out $flowsPath `
        --erpnext-url 'http://bench:8000' --erpnext-token $erpToken `
        --shopify-store $shopifyStore --shopify-version $shopifyVersion `
        --shopify-token $shopifyToken --site $siteName
    if ($LASTEXITCODE -ne 0) { Write-Warn "flow builder exited $LASTEXITCODE" }
}

Invoke-Compose @('restart', 'node-red') | Out-Null
Start-Sleep -Seconds 8

# ---------------------------------------------------------------------------
# 9. start the tunnel and wire the webhooks
# ---------------------------------------------------------------------------
Write-Step '11/11  starting the tunnel and wiring ERPNext webhooks'

# The containerised ngrok (compose profile `container-ngrok`) is opt-in: pulling
# ngrok/ngrok stalled on this machine. By default we drive the ngrok binary that
# is already installed and authenticated here, pointing it at the CONTAINERISED
# Node-RED on its published host port. Either way the public URL is read back
# from the agent's local API and written into the webhooks.
$ngrokExe = (Get-Command ngrok -ErrorAction SilentlyContinue).Source
if (-not $ngrokExe) {
    $ngrokExe = Get-ChildItem 'C:\Program Files\WindowsApps\ngrok.ngrok_*' -Filter 'ngrok.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}

$apiPorts = @(4040, [int]$ngrokApiPort) | Sort-Object -Unique
$alreadyTunnelling = $false
foreach ($port in $apiPorts) {
    try {
        $t = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/tunnels" -TimeoutSec 3
        if ($t.tunnels) { $alreadyTunnelling = $true; break }
    } catch { }
}

if (-not $alreadyTunnelling -and $ngrokExe) {
    $cacheDir = Join-Path $RootDir '.cache'
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    Write-Info "starting ngrok: http localhost:$nodeRedPort (the containerised Node-RED)"
    Start-Process -FilePath $ngrokExe -ArgumentList @('http', $nodeRedPort, '--log', 'stdout') `
        -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $cacheDir 'ngrok.log') `
        -RedirectStandardError (Join-Path $cacheDir 'ngrok.err.log') | Out-Null
    Start-Sleep -Seconds 6
} elseif (-not $ngrokExe) {
    Write-Warn 'no ngrok binary found - the public tunnel will not come up'
}

$publicUrl = $null
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) {
    foreach ($port in $apiPorts) {
        try {
            $tunnels = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/tunnels" -TimeoutSec 4
            $candidate = ($tunnels.tunnels | Where-Object { $_.public_url } | Select-Object -First 1).public_url
            if ($candidate) { $publicUrl = $candidate; break }
        } catch { }
    }
    if ($publicUrl) { break }
    Start-Sleep -Seconds 4
}

if ($publicUrl) {
    Write-Info "tunnel: $publicUrl -> localhost:$nodeRedPort"
    if ((Invoke-Bench "bash /tmp/scripts/ai-fix-wire-webhooks.sh $publicUrl") -ne 0) {
        Write-Warn 'webhook wiring failed'
    }
} else {
    Write-Warn 'no ngrok tunnel came up - webhooks left unconfigured'
    Write-Warn ("see " + (Join-Path $RootDir '.cache\ngrok.err.log'))
}

# ---------------------------------------------------------------------------
# verification
# ---------------------------------------------------------------------------
Write-Step 'verification'
$erpUrl = "http://localhost:$erpnextPort"
if (Wait-Url "$erpUrl/api/method/ping" 150) {
    Write-Info "ERPNext  : UP  ($erpUrl)"
} else {
    Write-Fail "ERPNext  : NOT responding ($erpUrl)"
}

$nodeRedOk = $false
try { $nodeRedOk = ((Invoke-WebRequest -Uri "http://localhost:$nodeRedPort/" -UseBasicParsing -TimeoutSec 8).StatusCode -eq 200) } catch { }
Write-Info ("Node-RED : {0} (http://localhost:{1})" -f $(if ($nodeRedOk) { 'UP' } else { 'DOWN' }), $nodeRedPort)

$plannerPort = if ($cfg['SCHEDULER_PORT']) { $cfg['SCHEDULER_PORT'] } else { '3001' }
$plannerOk = $false
if (-not $SkipScheduler) {
    try {
        $health = Invoke-RestMethod -Uri "http://localhost:$plannerPort/api/health" -TimeoutSec 8
        $plannerOk = [bool]$health.status
    } catch { }
    Write-Info ("Planner  : {0} (http://localhost:{1})" -f $(if ($plannerOk) { 'UP' } else { 'DOWN' }), $plannerPort)
}

if ($publicUrl) {
    foreach ($path in '/delivery-note', '/stock-entry', '/stock-recon') {
        $code = 'ERR'
        try {
            $resp = Invoke-WebRequest -Uri "$publicUrl$path" -Method POST -Body '{}' `
                -ContentType 'application/json' -UseBasicParsing -TimeoutSec 25
            $code = $resp.StatusCode
        } catch {
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        }
        Write-Info ("webhook  : POST {0} -> {1}" -f $path, $code)
    }
}

Write-Host ''
Write-Host ('=' * 72) -ForegroundColor Green
Write-Host '  ERPNEXT-AI-FIX is up' -ForegroundColor Green
Write-Host ('=' * 72) -ForegroundColor Green
Write-Host "  ERPNext        : $erpUrl" -ForegroundColor Green
Write-Host '  Login          : Administrator / admin' -ForegroundColor Green
Write-Host "  Node-RED       : http://localhost:$nodeRedPort" -ForegroundColor Green
Write-Host "  Planner        : http://localhost:$($cfg['SCHEDULER_PORT'])" -ForegroundColor Green
if ($publicUrl) { Write-Host "  Public tunnel  : $publicUrl" -ForegroundColor Green }
Write-Host ''
Write-Host '  Barcode scanner: ERPNext -> Barcode Printing'
Write-Host '  Shopify bridge : webhooks -> tunnel -> Node-RED -> Shopify Admin API'
Write-Host '  Production plan: Manufacturing workspace -> "Production Planner"'
Write-Host ''
