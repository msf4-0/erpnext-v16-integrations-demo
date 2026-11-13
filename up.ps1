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
    # Run from the repository root. There is exactly ONE bring-up script and it
    # is this file. The old sandbox\up.ps1 belonged to the retired
    # `erpnext-ai-fix` project, provisioned a DIFFERENT compose project, and has
    # been deleted - if you still have a copy, do not run it.
    powershell -ExecutionPolicy Bypass -File .\up.ps1
    powershell -ExecutionPolicy Bypass -File .\up.ps1 -Fresh
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
$script:RunStart = Get-Date

$DemoDir = $PSScriptRoot
# SELF-CONTAINED BY DEFAULT: everything this script stages (sandbox scripts,
# recipes, the Node-RED flow, the app sources under repos/, and the planner) lives
# inside comp_demo. The step-0 guard below falls back to ERPNEXT-AI-FIX only if the
# vendored sandbox is missing, so an in-flight run keeps working.
$SandboxDir = Join-Path $DemoDir 'sandbox'
$RootDir = $DemoDir
$ComposeFile = Join-Path $DemoDir 'docker-compose.yml'
$EnvPath = Join-Path $DemoDir '.env'
$Project = 'comp_demo'
$NgrokYml = Join-Path $env:LOCALAPPDATA 'Packages\ngrok.ngrok_1g87z0zv29zzc\LocalCache\Local\ngrok\ngrok.yml'

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$Message) {
    $elapsed = [int]((Get-Date) - $script:RunStart).TotalSeconds
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $Message   [+${elapsed}s]" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}
function Write-Info([string]$Message) { Write-Host "  $Message" }
function Write-Warn([string]$Message) { Write-Host "  WARN: $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "  FAIL: $Message" -ForegroundColor Red }

# Required-step bookkeeping. A WARN means "an optional integration is
# unavailable"; a FAIL means "a feature this repo advertises will not work".
# The script must never print a green banner over a failure - printing one over
# a half-installed stack is exactly how a broken setup got reported as a
# successful one.
$script:Failures = New-Object System.Collections.Generic.List[string]
function Add-Failure([string]$Name, [string]$Detail) {
    $script:Failures.Add("${Name}: $Detail")
    Write-Fail "$Name - $Detail"
}

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
    $lines = New-Object System.Collections.Generic.List[string]
    try {
        # Stream output AS THE COMMAND RUNS. The old `$raw = & $Exe @Arguments`
        # buffered every line until exit, so a 5-minute get-app/migrate/yarn step
        # printed nothing at all - long steps were indistinguishable from a hang,
        # and an interactive prompt from a child process could never be seen.
        & $Exe @Arguments 2>&1 | ForEach-Object {
            $text = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
            $lines.Add($text)
            if (-not $Capture) { Write-Host $text }
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($Capture) { return [pscustomobject]@{ Output = ($lines -join [Environment]::NewLine); Code = $code } }
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
# stdin is always redirected from /dev/null: `docker compose exec -T` leaves a
# pipe on stdin, so a bench/click prompt ("Do you want to rollback...?") waits
# for an answer that up.ps1 buffers and never shows - an invisible, CPU-free
# hang. With /dev/null the prompt hits EOF and aborts with a real error.
function Invoke-Bench { param([string]$Command) Invoke-Native -Exe $script:ComposeExe -Arguments ($script:composeBase + @('exec', '-T', 'bench', 'bash', '-lc', "$Command < /dev/null")) }
function Invoke-BenchRoot { param([string]$Command) Invoke-Native -Exe $script:ComposeExe -Arguments ($script:composeBase + @('exec', '-T', '-u', 'root', 'bench', 'bash', '-lc', "$Command < /dev/null")) }

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
# A fresh clone has no .env (it is git-ignored). Auto-create it from the example
# so a first-time user does not have to guess - they only fill in the Shopify /
# DB secrets afterwards. This was the #1 failure on a friend's machine.
if (-not (Test-Path $EnvPath)) {
    $envExample = Join-Path $DemoDir '.env.example'
    if (Test-Path $envExample) {
        Copy-Item -LiteralPath $envExample -Destination $EnvPath -Force
        Write-Warn '.env was missing - created from .env.example (fill in DB_ROOT_PASSWORD / Shopify secrets)'
    } else {
        throw "env file not found and no .env.example to copy: $EnvPath"
    }
}

# Self-containment guard (must run after the helpers exist so it can warn).
$vendored = Test-Path (Join-Path $SandboxDir 'scripts')
if (-not $vendored) {
    $SandboxDir = 'F:\ERPNEXT\ERPNEXT-AI-FIX\sandbox'
    $RootDir = 'F:\ERPNEXT\ERPNEXT-AI-FIX'
    Write-Warn "comp_demo\sandbox is missing - falling back to $RootDir"
}
$reposDir = Join-Path $RootDir 'repos'
if (-not (Test-Path $reposDir)) { throw "no repos/ under $RootDir - the app sources are missing" }
if ($vendored) { Write-Info "sources: $DemoDir (self-contained)" }

$cfg = Read-EnvFile $EnvPath
$erpnextPort = if ($cfg['ERPNEXT_PORT']) { $cfg['ERPNEXT_PORT'] } else { '8000' }
$nodeRedPort = if ($cfg['NODE_RED_PORT']) { $cfg['NODE_RED_PORT'] } else { '1881' }
$ngrokApiPort = if ($cfg['NGROK_API_PORT']) { $cfg['NGROK_API_PORT'] } else { '4041' }
$siteName = if ($cfg['SITE_NAME']) { $cfg['SITE_NAME'] } else { 'frontend' }
$erpVersion = if ($cfg['ERPNEXT_VERSION']) { $cfg['ERPNEXT_VERSION'] } else { '16' }
$shopifyStore = if ($cfg['SHOPIFY_STORE']) { $cfg['SHOPIFY_STORE'] } else { '4e1075.myshopify.com' }
$shopifyVersion = if ($cfg['SHOPIFY_API_VERSION']) { $cfg['SHOPIFY_API_VERSION'] } else { '2026-04' }
$shopifyToken = $cfg['SHOPIFY_ACCESS_TOKEN']
# Dev Dashboard app credentials: the Admin API token above is a 24h
# client-credentials token, so the app mints its own replacement from these.
# They are persisted into the site's site_config.json by shopify_sync.py.
$shopifyClientId = $cfg['SHOPIFY_CLIENT_ID']
$shopifyClientSecret = $cfg['SHOPIFY_CLIENT_SECRET']
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

# Self-heal the Node-RED flow paths. The .env.example ships stale absolute paths
# (F:\ERPNEXT\erpnext-build\...) that do not exist on a fresh clone; a bind-mount
# to a missing source makes `docker compose create` fail, which is the "could not
# build the image" error a fresh machine sees. Force both paths to resolve inside
# THIS project, whatever its clone location. Process env wins over --env-file for
# compose interpolation, so these override any stale .env value.
$env:FLOWS_PATH = Join-Path $SandboxDir 'node-red\flows.json'
$env:NODE_RED_SOURCE_FLOW = Join-Path $SandboxDir 'node-red\source-flow.json'

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
if ((Invoke-Compose @('create')) -ne 0) { throw 'docker compose create failed' }

# WHY NOT `docker compose up -d`: on this host `up` HANGS with the containers
# left in the `Created` state (Docker Desktop attaches agent hooks to the compose
# up subcommand; it affects the standalone docker-compose.exe shim too). `create`
# returns fine, and `docker start` on the created containers takes ~15 s, so we
# split the two - measured, not guessed.
$demoServices = @('db', 'redis-cache', 'redis-queue', 'bench', 'node-red', 'metabase')
$demoNames = $demoServices | ForEach-Object { "$Project-$_-1" }
if ((Invoke-Native -Exe 'docker' -Arguments (@('start') + $demoNames)) -ne 0) {
    throw 'docker start failed for the demo stack'
}
Write-Info ('containers started: ' + ($demoNames -join ', '))

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
# `chown -R` over the whole bench tree is minutes of work on Docker Desktop's
# Windows filesystem (venv + node_modules = ~200k files) and it is pointless
# when the tree already belongs to frappe, which is the normal case for the
# baked image. Only fix ownership when the bench root is actually wrong.
Invoke-BenchRoot 'if [ "$(stat -c %U /home/frappe/frappe-bench)" = frappe ]; then echo bench already frappe-owned; else chown -R frappe:frappe /home/frappe/frappe-bench; fi; echo chown-done' | Out-Null
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
$einvoiceSrc = Join-Path $reposDir 'eu_einvoice'
$trackingSrc = Join-Path $reposDir 'item_tracking'

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
# e-invoicing (best-effort: the original e_invoice_erp source is 404, so this
# uses the public alyf-de/eu_einvoice v16 branch instead).
if (Test-Path $einvoiceSrc) {
    Copy-Into $einvoiceSrc '/tmp/repos/eu_einvoice'
    Write-Info 'staged eu_einvoice (e-invoicing)'
} else {
    Write-Warn 'no eu_einvoice source under repos/ - e-invoicing will be skipped'
}
# Individual item tracking. REQUIRED by Barcode Printing's "Load Tracked Items"
# (one label per Tracked Item). Without it the doctype is absent, the app's
# app_include_js 404s and no unit labels can be printed.
if (Test-Path $trackingSrc) {
    Copy-Into $trackingSrc '/tmp/repos/item_tracking'
    Write-Info 'staged item_tracking (individual item tracking)'
} else {
    Write-Warn 'no item_tracking source under repos/ - unit labels will be unavailable'
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
    # The bench service runs `exec bench serve` as the container's PID 1, started
    # before the site existed. It cannot be restarted from inside (no procps in
    # the image, and killing it kills this exec session) and keeps replying
    # 404 "localhost does not exist" until the container is restarted, so do
    # that from here and wait for the site to answer.
    Write-Info 'restarting the bench container so bench serve reloads the new site'
    Invoke-Native -Exe 'docker' -Arguments @('restart', "$Project-bench-1") | Out-Null
    if (Wait-Url "http://localhost:$erpnextPort/api/method/ping" 180) {
        Write-Info "ERPNext is serving site '$siteName' on port $erpnextPort"
    } else {
        throw "ERPNext did not answer /api/method/ping on port $erpnextPort after the restart"
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
        Add-Failure 'apps' 'ai-fix-install.sh failed - barcode_shrdc / shopify are NOT installed'
    } else {
        Write-Info 'barcode_shrdc + shopify installed'
    }
    # 7b. e-invoicing - best-effort, never blocks the build.
    if (Test-Path $einvoiceSrc) {
        Write-Step '7b/11 installing eu_einvoice (e-invoicing) - best-effort'
        if ((Invoke-Bench 'bash /tmp/scripts/install-app.sh eu_einvoice /tmp/repos/eu_einvoice 16 /tmp/recipes/eu_einvoice.yaml') -ne 0) {
            Write-Warn 'eu_einvoice install reported errors - e-invoicing is optional, continuing'
        } else {
            Write-Info 'eu_einvoice (e-invoicing) installed'
        }
    }

    # 7b-2. item tracking - required by Barcode Printing's per-unit labels.
    if (Test-Path $trackingSrc) {
        Write-Step '7b-2/11 installing item_tracking (individual item tracking)'
        if ((Invoke-Bench 'bash /tmp/scripts/install-app.sh item_tracking /tmp/repos/item_tracking 16 /tmp/recipes/item_tracking.yaml') -ne 0) {
            Add-Failure 'item_tracking' 'install failed - Shift+I scanner and per-unit labels will not work'
        } else {
            Write-Info 'item_tracking (individual item tracking) installed'
        }
    }
} else {
    Write-Step '7/11  app install skipped (-SkipInstall)'
}

# ---------------------------------------------------------------------------
# 7c. app asset links
# ---------------------------------------------------------------------------
# `bench install-app` does NOT create the sites/assets/<app> symlink - only
# `bench build` does. Without it every entry in the app's `app_include_js`
# (/assets/<app>/js/*.js) 404s, and the desk reacts by RELOADING ITSELF in a
# loop, which looks like a broken site rather than a missing symlink.
Write-Step '7c/11  linking app assets (bench build)'
$nodeBin = 'export PATH=$(ls -d /home/frappe/.nvm/versions/node/*/bin 2>/dev/null | tail -1):$PATH'
$installed = (Invoke-Bench 'cat /home/frappe/frappe-bench/sites/apps.txt' -Capture).Output
foreach ($app in @($installed -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    if ($app -in @('frappe', 'erpnext')) { continue }
    # An app with no public/ directory ships no browser assets - nothing to link.
    if ((Invoke-Bench "test -d /home/frappe/frappe-bench/apps/$app/$app/public") -ne 0) { continue }
    # `test -e` succeeds only when the symlink target resolves
    if ((Invoke-Bench "test -e /home/frappe/frappe-bench/sites/assets/$app") -eq 0) {
        Write-Info "$app assets already linked"
        continue
    }
    Write-Info "linking $app assets"
    if ((Invoke-Bench "$nodeBin; cd /home/frappe/frappe-bench && bench build --app $app") -ne 0) {
        Write-Warn "bench build failed for $app - its app_include_js will 404 and the desk may reload-loop"
    }
}

# ---------------------------------------------------------------------------
# 7d. setup wizard must be marked complete
# ---------------------------------------------------------------------------
# `System Settings.setup_complete` ships as 0 in this image, and with it unset
# Frappe boots /desk into the setup wizard on EVERY document load:
#   - POST setup_wizard.load_languages fires on every single desk request
#   - the wizard's step route resolves to `undefined` -> GET /undefined 404
#   - the desk reloads and repeats, ~1 load/second, forever
# It is database state, so hard reloads, cache wipes and incognito all loop
# identically - which is why it looked like a client bug and was not one.
# The literals below are hex encoded: Invoke-Bench passes the command through
# `bash -lc`, and quoted/JSON arguments do not survive PowerShell's native
# quoting reliably. Hex has nothing to mangle.
Write-Step '7d/11  marking the setup wizard complete'
$siteExpr = '$(cat /home/frappe/frappe-bench/sites/currentsite.txt 2>/dev/null || echo frontend)'
$ssDoc = '0x53797374656d2053657474696e6773'   # System Settings
$ssFld = '0x73657475705f636f6d706c657465'     # setup_complete
$sqlRead = "select ifnull((select value from tabSingles where doctype = $ssDoc and field = $ssFld limit 1), 0) as v"
$setupVal = (Invoke-Bench ("cd /home/frappe/frappe-bench && bench --site " + $siteExpr + " mariadb -N -B -e '" + $sqlRead + "'") -Capture).Output.Trim()
if ($setupVal -match '^\s*(1|True)\s*$') {
    Write-Info 'setup_complete already 1'
} else {
    $sqlSet = "insert into tabSingles (doctype, field, value) values ($ssDoc, $ssFld, 0x31) on duplicate key update value = 0x31"
    Invoke-Bench ("cd /home/frappe/frappe-bench && bench --site " + $siteExpr + " mariadb -e '" + $sqlSet + "'") | Out-Null
    Invoke-Bench ("cd /home/frappe/frappe-bench && bench --site " + $siteExpr + " clear-cache") | Out-Null
    Write-Info 'setup_complete set to 1 (stops the desk setup-wizard reload loop)'
}

# The stale default that ACTUALLY caused the reload loop: `desktop:home_page`
# pointed at the setup-wizard page. boot.py resolves it into frappe.boot.home_page,
# so the desk routed to `setup-wizard/0` on every load and that page reloads the
# document - a clean ~2 document loads/second, forever, with no JS error at all.
$hpKey = '0x6465736b746f703a686f6d655f70616765'   # desktop:home_page
$hpRoot = '0x5f5f64656661756c74'                   # __default
$hpGood = '0x776f726b737061636573'                 # workspaces
$sqlHp = "select ifnull((select defvalue from tabDefaultValue where defkey = $hpKey and parent = $hpRoot limit 1), 0) as v"
$hpVal = (Invoke-Bench ("cd /home/frappe/frappe-bench && bench --site " + $siteExpr + " mariadb -N -B -e '" + $sqlHp + "'") -Capture).Output.Trim()
if ($hpVal -eq 'setup-wizard') {
    $sqlHpSet = "update tabDefaultValue set defvalue = $hpGood where defkey = $hpKey and parent = $hpRoot"
    Invoke-Bench ("cd /home/frappe/frappe-bench && bench --site " + $siteExpr + " mariadb -e '" + $sqlHpSet + "'") | Out-Null
    Invoke-Bench ("cd /home/frappe/frappe-bench && bench --site " + $siteExpr + " clear-cache") | Out-Null
    Write-Info 'desk home page moved off setup-wizard (stops the reload loop)'
} else {
    Write-Info ("desk home page is '" + $hpVal + "'")
}

# eu_einvoice's python deps. `bench install-app` skips an app's pyproject
# dependencies, so without these every eu_einvoice doctype throws
#   ModuleNotFoundError: No module named 'drafthorse'
# and the desk says "Module import failed for E Invoice Import".
Write-Step '7e/11  app python dependencies'
$depCmd = "/home/frappe/frappe-bench/env/bin/python -c 'import drafthorse, facturx, saxonche'"
$depOk = (Invoke-Bench "$depCmd && echo DEPSOK" -Capture).Output
if ($depOk -match 'DEPSOK') {
    Write-Info 'eu_einvoice deps already present'
} else {
    Invoke-Bench "/home/frappe/frappe-bench/env/bin/pip install --no-input 'factur-x~=3.1' 'drafthorse~=2025.2.0' 'saxonche>=12.5.0,<13.0.0'" | Out-Null
    $depOk = (Invoke-Bench "$depCmd && echo DEPSOK" -Capture).Output
    if ($depOk -match 'DEPSOK') { Write-Info 'installed eu_einvoice deps' }
    else { Write-Warn 'eu_einvoice deps still missing - E-Invoicing forms will not load' }
}

# ---------------------------------------------------------------------------
# 7f. Metabase: schema + grant + dashboard
# ---------------------------------------------------------------------------
# Metabase keeps its own metadata in the `metabase` schema of the `db` MariaDB,
# not in a volume, so anything that recreates db_data silently wipes the admin
# account, the ERPNext data source and every saved question/dashboard. The
# script below re-creates the schema/user/grant, waits for health, seeds the
# admin + data source if missing, and rebuilds the `ERPNext Monitoring`
# dashboard only when it is absent. Non-fatal: BI must not block the stack.
Write-Step '7f/11  Metabase schema + dashboard'
try {
    & (Join-Path $PSScriptRoot 'sandbox\scripts\ensure_metabase.ps1')
    & (Join-Path $PSScriptRoot 'sandbox\scripts\ensure_metabase_app.ps1')
} catch {
    Write-Warn ("metabase setup did not complete: " + $_.Exception.Message)
    Write-Warn 'run .\sandbox\scripts\ensure_metabase.ps1 once the container is healthy'
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

# 7c. demo master data that stock site provisioning skipped.
# Supplier Group / Stock Entry Type fixtures, the barcode client scripts and the
# scan resolver are all required for the barcode + master-data milestones: without
# them a Supplier cannot be created, no Stock Entry can be submitted and the
# scan_barcode field does nothing. The seeder is idempotent.
# 7c. (moved) Demo master data and the planner schema are seeded later - see
# steps 8b and 9b. They cannot run here: seed-demo-masters.py needs the Company
# and chart of accounts (step 8, bootstrap_masters.py) plus the PLN-* Items the
# Shopify product sync imports (also step 8), and seed-vwo-doctype.py's demo
# batch group needs the Work Orders the planner creates in step 9. Running them
# here produced "Could not find Company: SHRDC" for every demo document.


# ---------------------------------------------------------------------------
# 8. Shopify post-setup: v16 item fix, master data, product/order sync
# ---------------------------------------------------------------------------
Write-Step '8/11  Shopify post-setup (master data + product/order sync)'
if ($shopifyToken) {
    if ((Invoke-Bench "bash /tmp/scripts/ai-fix-postsetup.sh $shopifyToken $shopifyStore $shopifyVersion $shopifyClientId $shopifyClientSecret") -ne 0) {
        Write-Warn 'Shopify post-setup reported errors - review the output above'
    }
} else {
    Write-Warn 'SHOPIFY_ACCESS_TOKEN is blank - skipping the Shopify sync entirely'
}

# ---------------------------------------------------------------------------
# 8b. demo master data + demo documents
# ---------------------------------------------------------------------------
# This MUST run after step 8: it needs the Company/chart of accounts that
# bootstrap_masters.py creates and the PLN-* Items that the Shopify product sync
# imports. Ordered before step 8 (as it used to be) every demo document failed
# with "Could not find Company: SHRDC".
if (-not $SkipInstall) {
    Write-Step '8b/11  demo master data (suppliers, stock entry types, barcode scan, demo docs)'
    if ((Invoke-Bench 'cd /home/frappe/frappe-bench && SITE_NAME=frontend ./env/bin/python /tmp/scripts/seed-demo-masters.py') -ne 0) {
        Add-Failure 'seed-masters' 'demo master data seeding failed - demo documents will be incomplete'
    } else {
        Write-Info 'demo master data seeded (supplier groups, stock entry types, barcode scanning, demo docs)'
    }
}

# ---------------------------------------------------------------------------
# 8c. demo user role + login (non-admin, for "ready for user use")
# ---------------------------------------------------------------------------
if (-not $SkipProvision) {
    Write-Step '8c/11  demo user role + login (Demo User role, demo@compdemo.local)'
    if ((Invoke-Bench 'cd /home/frappe/frappe-bench && SITE_NAME=frontend ./env/bin/python /tmp/scripts/create-demo-user.py') -ne 0) {
        Write-Warn 'demo user creation reported errors - review the output above'
    } else {
        Write-Info 'Demo User role + demo@compdemo.local / demo ready (non-admin)'
    }
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
        & (Join-Path $DemoDir 'scheduler-up.ps1') -SkipBuild
        if ($LASTEXITCODE -ne 0) { Write-Warn 'the planner did not verify - review the output above' }
    } catch {
        Write-Warn "planner bring-up failed: $($_.Exception.Message)"
    }
} else {
    Write-Step '9/11  production planner skipped (-SkipScheduler)'
}

# ---------------------------------------------------------------------------
# 9b. planner schema: the `Virtual Work Order` doctype
# ---------------------------------------------------------------------------
# server.js reads/writes `/Virtual Work Order` for batch groups, timers and the
# schedule feed. The doctype is not part of any installed app, so without this
# step every one of those paths 404s and the Batch / Timers tabs come up empty.
# It runs AFTER step 9 because the demo batch group groups real Work Orders.
if (-not $SkipInstall) {
    Write-Step '9b/11  planner schema (Virtual Work Order doctype + demo batch group)'
    if ((Invoke-Bench 'cd /home/frappe/frappe-bench && SITE_NAME=frontend ./env/bin/python /tmp/scripts/seed-vwo-doctype.py') -ne 0) {
        Add-Failure 'virtual-work-order' 'Virtual Work Order seeding failed - planner Batch/Timers tabs will be empty'
    } else {
        Write-Info 'Virtual Work Order doctype + demo batch group ready'
        # `Virtual Work Order` is created here, after step 8c granted the demo
        # role its permissions, so on a fresh site the demo user would have no
        # access to it. The script is idempotent and only re-syncs the rules.
        if (-not $SkipProvision) {
            Invoke-Bench 'cd /home/frappe/frappe-bench && SITE_NAME=frontend ./env/bin/python /tmp/scripts/create-demo-user.py' | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# 10. build the flow + restart Node-RED
# ---------------------------------------------------------------------------
Write-Step '10/11  building the Node-RED flow'

$flowSrc = $cfg['NODE_RED_SOURCE_FLOW']
if (-not $flowSrc -or -not (Test-Path $flowSrc)) {
    # vendored next to the flow builder (the old F:\shopify_erpnext_integration.json
    # is outside the project and would break a copy of comp_demo)
    $fallback = Join-Path $SandboxDir 'node-red\source-flow.json'
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
    # Let ngrok write its own log file and launch it fully detached. Using
    # -RedirectStandardOutput/-RedirectStandardError here handed the pipe that
    # up.ps1's output was captured on to ngrok, which then outlives the script:
    # the parent PowerShell could not exit until the tunnel closed, so a
    # 3.5-minute run looked like a 7.5-minute one with nothing left to print.
    $ngrokLog = Join-Path $cacheDir 'ngrok.log'
    Remove-Item -LiteralPath $ngrokLog -ErrorAction SilentlyContinue
    Start-Process -FilePath $ngrokExe -ArgumentList @('http', $nodeRedPort, '--log', $ngrokLog) `
        -WindowStyle Hidden | Out-Null
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
    Write-Warn ("see " + (Join-Path $RootDir '.cache\ngrok.log'))
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
    $script:Failures.Add("erpnext: not responding at $erpUrl")
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
Write-Host '  Demo user      : demo@compdemo.local / demo (Demo User role, non-admin)' -ForegroundColor Green
Write-Host "  Node-RED       : http://localhost:$nodeRedPort" -ForegroundColor Green
Write-Host "  Planner        : http://localhost:$($cfg['SCHEDULER_PORT'])" -ForegroundColor Green
if ($publicUrl) { Write-Host "  Public tunnel  : $publicUrl" -ForegroundColor Green }
Write-Host ''
Write-Host '  Barcode scanner: ERPNext -> Barcode Printing'
Write-Host '  Shopify bridge : webhooks -> tunnel -> Node-RED -> Shopify Admin API'
Write-Host '  Production plan: Manufacturing workspace -> "Production Planner"'
Write-Host ''

# ---------------------------------------------------------------------------
# feature assertions
# ---------------------------------------------------------------------------
# A 200 on /login proves only that the web server is up. An app whose
# app_include_js 404s still serves a 200 HTML shell, and a missing doctype still
# looks like "the page is just empty". These check the actual features the
# repo advertises, and each failure is fatal.
function Test-Feature([string]$Name, [string]$Url, [hashtable]$Headers = @{}) {
    $code = 'ERR'
    try {
        $r = Invoke-WebRequest -Uri $Url -Headers $Headers -UseBasicParsing -TimeoutSec 25
        $code = [int]$r.StatusCode
    } catch {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    }
    if ($code -eq 200) { Write-Info ("feature  : {0,-26} OK" -f $Name) }
    else { Add-Failure $Name ("expected 200, got $code - $Url") }
}

$authHeaders = @{ Authorization = "token $erpToken" }
Test-Feature 'barcode app'   "$erpUrl/api/resource/Barcode%20Printing"   $authHeaders
Test-Feature 'barcode page'  "$erpUrl/item_qr?item_code=PLN-BRACKET"
Test-Feature 'item tracking' "$erpUrl/assets/item_tracking/js/item_tracking_scan.js"
Test-Feature 'e-invoicing'   "$erpUrl/api/resource/E%20Invoice%20Import"  $authHeaders
Test-Feature 'barcode scan js' "$erpUrl/assets/barcode_shrdc/js/scanner_barcode_patch.js"
Test-Feature 'barcode link js' "$erpUrl/assets/barcode_shrdc/js/barcode_create_links.js"
# ---------------------------------------------------------------------------
# exit contract
# ---------------------------------------------------------------------------
# 0 = every required step produced the feature it advertises.
# 1 = the containers may be running, but at least one advertised feature is not
#     installed. setup.ps1, CI and colleagues can rely on this.
if ($script:Failures.Count -gt 0) {
    Write-Host ('=' * 72) -ForegroundColor Red
    Write-Host ("  SETUP INCOMPLETE - $($script:Failures.Count) required step(s) failed") -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host "   - $f" -ForegroundColor Red }
    Write-Host '  The containers are up, but the features above will not work.' -ForegroundColor Red
    Write-Host '  Re-run the failing part:  .\up.ps1 -SkipProvision -SkipInstall' -ForegroundColor Red
    Write-Host ('=' * 72) -ForegroundColor Red
    exit 1
}
Write-Host '  All required steps verified - setup complete.' -ForegroundColor Green
exit 0
