<#
.SYNOPSIS
    Idempotent setup for a Shopify -> ERPNext integration bridged by Node-RED.

.DESCRIPTION
    Configures, in this order: Node-RED, the ngrok tunnel, a Shopify Admin API
    token, ERPNext API keys, the Shopify Access record, the Node-RED flow
    (credentials + URLs), the three ERPNext webhooks, then smoke-tests all of it.

    Every step checks state first and then reports [OK] | [SKIP] | [FIXED] |
    [WARN] | [FAIL]. Re-running is safe: nothing is written when it already
    matches, and no credential is rotated unless it is actually dead.

    Secrets are read from .env, never written into this script, and masked in
    all console output and in the log file.

.PARAMETER SkipInstall
    Never install or start anything (no `npm install -g`, no new processes).
    Use it when the services are managed elsewhere - e.g. when this build's
    Node-RED runs as a Docker container.

.PARAMETER WhatIf
    Dry run. Reports what would change, writes nothing, starts nothing.
    (Standard PowerShell -WhatIf.)

.PARAMETER EnvFile
    The Shopify integration env file. Defaults to `.env` beside this script.

.PARAMETER BaseEnvFile
    Layered underneath EnvFile. Defaults to the build's own `.env`
    (one directory up), so store/client credentials are inherited.

.PARAMETER NoLayering
    Use EnvFile only; ignore the parent build env file.

.PARAMETER ForceToken
    Mint a fresh Shopify token and re-run steps 5-7 even if the current one
    still works. Needed after rotating the client secret.

.PARAMETER SkipFlowDeploy
    Patch and back up the flow but do not POST it to Node-RED.

.EXAMPLE
    pwsh -File .\setup-shopify-erpnext.ps1 -WhatIf

.EXAMPLE
    pwsh -File .\setup-shopify-erpnext.ps1

.EXAMPLE
    pwsh -File .\setup-shopify-erpnext.ps1 -SkipInstall -Verbose
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipInstall,
    [switch]$ForceToken,
    [switch]$SkipFlowDeploy,
    [switch]$NoLayering,
    [string]$EnvFile,
    [string]$BaseEnvFile,
    [string]$LogFile
)

# NOTE: deliberately NOT Set-StrictMode. Everything below walks JSON documents
# from the Shopify and ERPNext APIs, where absent properties are normal (a
# `tab` node has no `name`, an error body has no `message`). Strict mode turns
# every one of those into a terminating error.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $EnvFile) { $EnvFile = Join-Path $PSScriptRoot '.env' }
if (-not $BaseEnvFile) { $BaseEnvFile = Join-Path (Split-Path $PSScriptRoot -Parent) '.env' }
if (-not $LogFile) { $LogFile = Join-Path $PSScriptRoot 'setup-shopify-erpnext.log' }

# ===========================================================================
# logging + masking
# ===========================================================================
$script:Secrets = [System.Collections.Generic.List[string]]::new()
$script:Results = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Secret([string]$value) {
    if ($value -and $value.Length -ge 4 -and -not $script:Secrets.Contains($value)) {
        [void]$script:Secrets.Add($value)
    }
}

# Belt and braces: even a secret that never passed through Add-Secret is
# caught by these shapes.
$MaskPatterns = @(
    'shpat_[0-9A-Za-z]+'
    'shpss_[0-9A-Za-z]+'
    'shpca_[0-9A-Za-z]+'
    '(?<=token )[0-9A-Za-z]{6,}:[0-9A-Za-z]{6,}'
    '(?<=Authorization: token )[^\s"]+'
    '2[0-9A-Za-z]{7}_[0-9A-Za-z]{10,}'   # ngrok authtoken shape
)

function Mask-Secrets([string]$text) {
    if (-not $text) { return $text }
    $out = $text
    foreach ($s in $script:Secrets) {
        if ($s -and $s.Length -ge 4) { $out = $out.Replace($s, '***') }
    }
    foreach ($p in $MaskPatterns) { $out = [regex]::Replace($out, $p, '***') }
    return $out
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('OK', 'SKIP', 'FIXED', 'WARN', 'FAIL', 'INFO', 'STEP', 'DRY')]
        [string]$Level = 'INFO'
    )
    $colour = switch ($Level) {
        'OK' { 'Green' } 'SKIP' { 'DarkGray' } 'FIXED' { 'Yellow' }
        'WARN' { 'Yellow' } 'FAIL' { 'Red' } 'STEP' { 'Cyan' } 'DRY' { 'Magenta' }
        default { 'Gray' }
    }
    $safe = Mask-Secrets $Message
    $tag = if ($Level -eq 'STEP') { '' } else { '[{0,-5}] ' -f $Level }
    Write-Host ("  {0}{1}" -f $tag, $safe) -ForegroundColor $colour
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    # -WhatIf:$false - the log is diagnostic, not a mutating action; without
    # this, -WhatIf makes Add-Content print "What if: Performing ..." for every
    # single log line and writes nothing.
    try { Add-Content -LiteralPath $LogFile -Value "$stamp [$Level] $safe" -Encoding utf8 -WhatIf:$false } catch { }
}

function Write-Step([string]$n, [string]$title) {
    Write-Host ''
    Write-Host ('-' * 74) -ForegroundColor DarkCyan
    Write-Log "STEP $n  $title" STEP
    Write-Host ('-' * 74) -ForegroundColor DarkCyan
}

function Add-Result([string]$Check, [string]$Status, [string]$Detail = '') {
    $script:Results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = Mask-Secrets $Detail })
}

# Honour -WhatIf without threading $PSCmdlet into every helper.
$script:DryRun = [bool]$WhatIfPreference
function Test-Gate([string]$what) {
    if ($script:DryRun) { Write-Log "WOULD $what" DRY; return $false }
    return $true
}

# ===========================================================================
# .env loading (layered) + config
# ===========================================================================
function Read-EnvFileStrict([string]$path) {
    $table = [ordered]@{}
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $table }
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $key = $Matches[1]
            $val = $Matches[2]
            # strip one layer of matching quotes
            if ($val.Length -ge 2 -and (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'")))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
            $table[$key] = $val
        }
    }
    return $table
}

$script:Config = [ordered]@{}
$script:ConfigSource = @{}

function Load-Layer([string]$path, [string]$label) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $t = Read-EnvFileStrict $path
    foreach ($k in $t.Keys) {
        if ($t[$k] -ne '') {
            $script:Config[$k] = $t[$k]
            $script:ConfigSource[$k] = $label
        } elseif (-not $script:Config.Contains($k)) {
            $script:Config[$k] = ''
            $script:ConfigSource[$k] = $label
        }
    }
}

function Get-Cfg([string]$key, [string]$default = '') {
    if ($script:Config.Contains($key) -and $script:Config[$key] -ne '') { return [string]$script:Config[$key] }
    return $default
}

# BOM-safe .env write (Windows PowerShell's UTF8 encoder adds a BOM, which
# breaks the FIRST variable in the file for any dotenv parser).
function Set-EnvValue([string]$path, [string]$key, [string]$value) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $lines = [System.Collections.Generic.List[string]](@(Get-Content -LiteralPath $path))
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") { $lines[$i] = "$key=$value"; $found = $true; break }
    }
    if (-not $found) { $lines.Add("$key=$value") }
    [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Step '0' 'Loading configuration'

if (-not $NoLayering) { Load-Layer $BaseEnvFile "base($([System.IO.Path]::GetFileName((Split-Path $BaseEnvFile -Parent)))/.env)" }
Load-Layer $EnvFile 'local(.env)'

if (-not (Test-Path -LiteralPath $EnvFile)) {
    Write-Log "no env file at $EnvFile - copy .env.example to .env first" FAIL
    exit 1
}
Write-Log "env: $EnvFile" INFO
if (-not $NoLayering) { Write-Log "env: $BaseEnvFile (layered underneath)" INFO }

# --- aliases so this build's own .env keys are inherited -------------------
# build .env ships SHOPIFY_STORE / ERPNEXT_API_TOKEN / ERPNEXT_PORT; the
# integration uses SHOPIFY_SHOP / ERP_API_TOKEN / ERP_URL.
if (-not (Get-Cfg 'SHOPIFY_SHOP') -and (Get-Cfg 'SHOPIFY_STORE')) { $script:Config['SHOPIFY_SHOP'] = Get-Cfg 'SHOPIFY_STORE' }
if (-not (Get-Cfg 'SHOPIFY_API_VERSION') -and (Get-Cfg 'SHOPIFY_API_VERSION')) { }
if (-not (Get-Cfg 'ERP_API_TOKEN') -and (Get-Cfg 'ERPNEXT_API_TOKEN')) { $script:Config['ERP_API_TOKEN'] = Get-Cfg 'ERPNEXT_API_TOKEN' }
if (-not (Get-Cfg 'ERP_URL') -and (Get-Cfg 'ERPNEXT_PORT')) { $script:Config['ERP_URL'] = "http://localhost:$(Get-Cfg 'ERPNEXT_PORT')" }

$ShopHost        = Get-Cfg 'SHOPIFY_SHOP'
$ShopClientId    = Get-Cfg 'SHOPIFY_CLIENT_ID'
$ShopClientSecret = Get-Cfg 'SHOPIFY_CLIENT_SECRET'
$ShopApiVersion  = Get-Cfg 'SHOPIFY_API_VERSION' '2026-04'
$NgrokAuthToken  = Get-Cfg 'NGROK_AUTHTOKEN'
$NgrokDomain     = Get-Cfg 'NGROK_DOMAIN'
$ErpUrl          = (Get-Cfg 'ERP_URL' 'http://localhost:8000').TrimEnd('/')
$ErpInternalUrl  = (Get-Cfg 'ERP_INTERNAL_URL' $ErpUrl).TrimEnd('/')
$ErpAdminUser    = Get-Cfg 'ERP_ADMIN_USER' 'Administrator'
$ErpAdminPass    = Get-Cfg 'ERP_ADMIN_PASSWORD'
$WebhookSecret   = Get-Cfg 'WEBHOOK_SECRET'
$ErpCompany      = Get-Cfg 'ERP_COMPANY'
# ERPNext site name - needed by every `bench --site <site>` call below.
$siteName        = Get-Cfg 'SITE_NAME' 'frontend'
$ErpCostCenter   = Get-Cfg 'ERP_COST_CENTER'
$ErpCashBank     = Get-Cfg 'ERP_CASH_BANK_ACCOUNT'
$ErpBankAccount  = Get-Cfg 'ERP_BANK_ACCOUNT'
$ErpWarehouse    = Get-Cfg 'ERP_WAREHOUSE'
$ErpPriceList    = Get-Cfg 'ERP_PRICE_LIST'
$ErpTaxAccount   = Get-Cfg 'ERP_TAX_ACCOUNT'
$NodeRedUrl      = (Get-Cfg 'NODE_RED_URL' 'http://localhost:1880').TrimEnd('/')
$NodeRedPort     = [int](Get-Cfg 'NODE_RED_PORT' '1880')
$NodeRedContainer = Get-Cfg 'NODE_RED_CONTAINER' 'comp_demo-node-red-1'
# Bench container, used to write Webhooks through the server-side document API
# (the REST resource endpoint mangles child rows on this Frappe build).
$BenchContainer   = Get-Cfg 'ERP_BENCH_CONTAINER' 'comp_demo-bench-1'
$FlowJsonPath    = Get-Cfg 'FLOW_JSON_PATH' '.\shopify_erpnext_integration.json'

# register secrets so nothing can leak into a log line
foreach ($s in @($ShopClientSecret, $NgrokAuthToken, $ErpAdminPass, $WebhookSecret)) { Add-Secret $s }

# resolve the flow path relative to this script
if (-not [System.IO.Path]::IsPathRooted($FlowJsonPath)) {
    $FlowJsonPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $FlowJsonPath))
}

# ===========================================================================
# tiny HTTP helper: never throws on 4xx/5xx, always returns status + body
# ===========================================================================
function Invoke-Api {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        $Body,
        [hashtable]$Headers,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [string]$ContentType,
        [int]$TimeoutSec = 45
    )
    # Written to run on Windows PowerShell 5.1 AND PowerShell 7: 5.1 has no
    # -SkipHttpErrorCheck / -StatusCodeVariable, so errors are caught and the
    # status + body are read off the response object instead.
    $p = @{
        Method      = $Method
        Uri         = $Uri
        TimeoutSec  = $TimeoutSec
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) { $p['Body'] = $Body }
    if ($Headers) { $p['Headers'] = $Headers }
    if ($Session) { $p['WebSession'] = $Session }
    if ($ContentType) { $p['ContentType'] = $ContentType }
    try {
        $data = Invoke-RestMethod @p
        return [pscustomobject]@{ Ok = $true; Status = 200; Data = $data; Error = $null }
    } catch {
        $status = 0
        $bodyText = ''
        $resp = $null
        try { $resp = $_.Exception.Response } catch { }
        if ($resp) {
            try { $status = [int]$resp.StatusCode } catch { try { $status = [int]$resp.StatusCode.value__ } catch { $status = 0 } }
            try {
                $stream = $resp.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $bodyText = $reader.ReadToEnd()
                    $reader.Dispose()
                }
            } catch { }
        }
        return [pscustomobject]@{
            Ok     = $false
            Status = $status
            Data   = $bodyText
            Error  = (Mask-Secrets $_.Exception.Message)
        }
    }
}

function Format-ApiError($resp) {
    if (-not $resp) { return 'no response' }
    # Prefer the response BODY: Node-RED and Frappe both put the real reason
    # there ("EBUSY: ...", "DocType w not found"), and the .NET exception text
    # is just "The remote server returned an error: (400) Bad Request."
    $body = ''
    if ($resp.Data -is [string]) { $body = $resp.Data }
    elseif ($resp.Data) { try { $body = ($resp.Data | ConvertTo-Json -Depth 4 -Compress) } catch { $body = "$($resp.Data)" } }
    if (-not $body -and $resp.Error) { $body = $resp.Error }
    if ($body.Length -gt 400) { $body = $body.Substring(0, 400) + '...' }
    return "HTTP $($resp.Status): $(Mask-Secrets $body)"
}

function Test-TcpPort([string]$hostName, [int]$port, [int]$timeoutMs = 1200) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($hostName, $port)
        return ($task.Wait($timeoutMs) -and $client.Connected)
    } catch { return $false } finally { $client.Dispose() }
}

# Null-safe property read for API payloads: Get-Obj $resp 'data.data[0].name'
function Get-Obj($obj, [string]$path, $default = $null) {
    if ($null -eq $obj) { return $default }
    foreach ($seg in $path.Split('.')) {
        if ($null -eq $obj) { return $default }
        if ($seg -match '^(.*)\[(\d+)\]$') {
            $name = $Matches[1]
            $idx = [int]$Matches[2]
            if ($name) {
                $p = $obj.PSObject.Properties[$name]
                if (-not $p) { return $default }
                $obj = $p.Value
            }
            if ($null -eq $obj) { return $default }
            $arr = @($obj)
            if ($idx -ge $arr.Count) { return $default }
            $obj = $arr[$idx]
            continue
        }
        $p = $obj.PSObject.Properties[$seg]
        if (-not $p) { return $default }
        $obj = $p.Value
    }
    if ($null -eq $obj) { return $default }
    return $obj
}

# ===========================================================================
# 0. preflight
# ===========================================================================
Write-Step '0' 'Preflight: tools, Docker, ERPNext, configuration'

$fatal = $false

# binaries
foreach ($exe in 'node', 'npm', 'docker', 'ngrok') {
    $c = Get-Command $exe -ErrorAction SilentlyContinue
    if ($c) { Write-Log "$exe -> $($c.Source)" OK }
    elseif ($exe -eq 'node' -or $exe -eq 'docker') { Write-Log "$exe not found on PATH" FAIL; $fatal = $true }
    else { Write-Log "$exe not found on PATH (needed for steps 1-2)" WARN }
}

# docker daemon
if (Get-Command docker -ErrorAction SilentlyContinue) {
    $dc = & docker info --format '{{.ServerVersion}}' 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Log "docker daemon up (server $($dc.ToString().Trim()))" OK }
    else { Write-Log 'docker daemon is not running - start Docker Desktop' FAIL; $fatal = $true }
}

# ERPNext reachable
$ping = Invoke-Api -Method GET -Uri "$ErpUrl/api/method/ping" -TimeoutSec 15
if ($ping.Ok) { Write-Log "ERPNext reachable at $ErpUrl" OK }
else { Write-Log "ERPNext not reachable at $ErpUrl ($(Format-ApiError $ping))" FAIL; $fatal = $true }

# required config
$required = [ordered]@{
    SHOPIFY_SHOP          = $ShopHost
    SHOPIFY_CLIENT_ID     = $ShopClientId
    SHOPIFY_CLIENT_SECRET = $ShopClientSecret
    ERP_ADMIN_PASSWORD    = $ErpAdminPass
    ERP_COMPANY           = $ErpCompany
}
$missing = @($required.Keys | Where-Object { -not $required[$_] })
if ($missing.Count -gt 0) {
    Write-Log ("missing required value(s) in .env: " + ($missing -join ', ')) FAIL
    $fatal = $true
}
if (-not $WebhookSecret) { Write-Log 'WEBHOOK_SECRET is empty - webhooks will be sent without X-Webhook-Secret' WARN }
if (-not $NgrokDomain) { Write-Log 'NGROK_DOMAIN is empty - the tunnel will use a random domain and webhook URLs will change each restart' WARN }
if (-not (Test-Path -LiteralPath $FlowJsonPath)) { Write-Log "FLOW_JSON_PATH not found: $FlowJsonPath" FAIL; $fatal = $true }
else { Write-Log "flow: $FlowJsonPath" OK }

if ($fatal) { Write-Log 'preflight failed - nothing was changed' FAIL; exit 1 }

# ===========================================================================
# 1. Node-RED
# ===========================================================================
Write-Step '1/9' 'Node-RED'

$nrRunning = Test-TcpPort '127.0.0.1' $NodeRedPort
if ($nrRunning) {
    $nrFlows = Invoke-Api -Method GET -Uri "$NodeRedUrl/flows" -TimeoutSec 10
    if ($nrFlows.Ok) {
        Write-Log "Node-RED already listening on $NodeRedPort (admin API reachable)" SKIP
        Add-Result 'Node-RED' 'SKIP' 'already running'
    } else {
        Write-Log "port $NodeRedPort is in use but the admin API did not answer" WARN
        Add-Result 'Node-RED' 'WARN' "port busy, admin API $($nrFlows.Status)"
    }
} elseif ($SkipInstall) {
    Write-Log "Node-RED is not listening on $NodeRedPort and -SkipInstall was given" FAIL
    Add-Result 'Node-RED' 'FAIL' 'not listening, -SkipInstall'
    $fatal = $true
} else {
    $nrCmd = Get-Command node-red -ErrorAction SilentlyContinue
    if (-not $nrCmd) {
        if (Test-Gate 'npm install -g node-red') {
            Write-Log 'installing node-red globally' INFO
            & npm install -g node-red 2>&1 | ForEach-Object { Write-Verbose (Mask-Secrets "$_") }
            if ($LASTEXITCODE -ne 0) { Write-Log 'npm install -g node-red failed' FAIL; $fatal = $true }
            else { Write-Log 'node-red installed' FIXED }
            $nrCmd = Get-Command node-red -ErrorAction SilentlyContinue
        }
    }
    if ($nrCmd -and (Test-Gate 'start node-red in a new window')) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoExit', '-Command', 'node-red' -WindowStyle Normal
        Write-Log 'node-red started in a new window' FIXED
        $deadline = (Get-Date).AddSeconds(120)
        do {
            Start-Sleep -Seconds 3
            $probe = Invoke-Api -Method GET -Uri "$NodeRedUrl/flows" -TimeoutSec 5
        } while ((Get-Date) -lt $deadline -and -not $probe.Ok)
        if ($probe.Ok) { Write-Log 'Node-RED is up' OK; Add-Result 'Node-RED' 'FIXED' 'started' }
        else { Write-Log 'Node-RED did not answer within 120s' FAIL; Add-Result 'Node-RED' 'FAIL' 'no response'; $fatal = $true }
    }
}

# ===========================================================================
# 2. ngrok tunnel
# ===========================================================================
Write-Step '2/9' 'ngrok public tunnel'

$script:PublicUrl = $null

function Get-NgrokPublicUrl {
    foreach ($port in @(4040, 4041)) {
        $t = Invoke-Api -Method GET -Uri "http://127.0.0.1:$port/api/tunnels" -TimeoutSec 4
        if ($t.Ok -and $t.Data.tunnels) {
            $u = ($t.Data.tunnels | Where-Object { $_.public_url } | Select-Object -First 1).public_url
            if ($u) { return $u }
        }
    }
    return $null
}

$existingUrl = Get-NgrokPublicUrl
$hostMatches = $false
if ($existingUrl -and $NgrokDomain) {
    try { $hostMatches = ([uri]$existingUrl).Host -eq $NgrokDomain } catch { $hostMatches = $false }
}

if ($existingUrl -and ($hostMatches -or -not $NgrokDomain)) {
    $script:PublicUrl = $existingUrl
    Write-Log "tunnel already up: $existingUrl" SKIP
    Add-Result 'ngrok' 'SKIP' $existingUrl
} elseif ($SkipInstall) {
    if ($existingUrl) {
        $script:PublicUrl = $existingUrl
        Write-Log "a tunnel exists but its domain is not $NgrokDomain; leaving it alone (-SkipInstall)" WARN
        Add-Result 'ngrok' 'WARN' $existingUrl
    } else {
        Write-Log 'no tunnel and -SkipInstall was given' FAIL
        Add-Result 'ngrok' 'FAIL' 'no tunnel, -SkipInstall'
        $fatal = $true
    }
} else {
    if ($NgrokAuthToken) {
        if (Test-Gate 'ngrok config add-authtoken') {
            & ngrok config add-authtoken $NgrokAuthToken 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Log 'ngrok authtoken registered' OK }
            else { Write-Log 'ngrok config add-authtoken failed' WARN }
        }
    }
    if (Test-Gate "start ngrok on port $NodeRedPort") {
        $args = @('http')
        if ($NgrokDomain) { $args += "--url=$NgrokDomain" }
        $args += "$NodeRedPort"
        Start-Process -FilePath 'ngrok' -ArgumentList $args -WindowStyle Minimized
        Write-Log ("ngrok started: " + ($args -join ' ')) FIXED
        $deadline = (Get-Date).AddSeconds(60)
        do {
            Start-Sleep -Seconds 3
            $script:PublicUrl = Get-NgrokPublicUrl
        } while ((Get-Date) -lt $deadline -and -not $script:PublicUrl)
        if ($script:PublicUrl) { Write-Log "public URL: $($script:PublicUrl)" OK; Add-Result 'ngrok' 'FIXED' $script:PublicUrl }
        else { Write-Log 'ngrok did not report a tunnel within 60s' FAIL; Add-Result 'ngrok' 'FAIL' 'no tunnel'; $fatal = $true }
    }
}

if ($script:PublicUrl -and $NgrokDomain) {
    $actualHost = try { ([uri]$script:PublicUrl).Host } catch { '' }
    if ($actualHost -ne $NgrokDomain) {
        Write-Log "tunnel host '$actualHost' does not match NGROK_DOMAIN '$NgrokDomain' - webhook URLs will use the tunnel host" WARN
    }
}

if ($fatal) { Write-Log 'cannot continue without a public tunnel - webhook URLs cannot be built' FAIL; exit 1 }

# ===========================================================================
# 3. Shopify Admin API token (client_credentials)
# ===========================================================================
Write-Step '3/9' 'Shopify Admin API token'

$script:ShopifyToken = $null
$tokenMinted = $false

# Reuse the previous token while it is still good. Minting on every run would
# rewrite the flow (the token is baked into 5 nodes) and bounce Node-RED for no
# reason - the opposite of idempotent. -ForceToken overrides this.
$cachedToken = Get-Cfg 'SHOPIFY_ACCESS_TOKEN'
$cachedExp = Get-Cfg 'SHOPIFY_TOKEN_EXPIRES'
$cachedUsable = $false
if ($cachedToken -and $cachedExp -and -not $ForceToken) {
    $expiry = [datetime]::MinValue
    try { $expiry = [datetime]::Parse($cachedExp, [System.Globalization.CultureInfo]::InvariantCulture) } catch { $expiry = [datetime]::MinValue }
    if ($expiry -gt (Get-Date).AddMinutes(5)) {
        $probe = Invoke-Api -Method GET -Uri "https://$ShopHost/admin/api/$ShopApiVersion/shop.json" `
            -Headers @{ 'X-Shopify-Access-Token' = $cachedToken } -TimeoutSec 25
        $cachedUsable = $probe.Ok
    }
}

if ($cachedUsable) {
    $script:ShopifyToken = $cachedToken
    Add-Secret $cachedToken
    Write-Log "cached Shopify token still valid (expires $cachedExp) - not re-minting" SKIP
    Add-Result 'Shopify token' 'SKIP' "cached until $cachedExp"
} else {

$body = @{
    grant_type    = 'client_credentials'
    client_id     = $ShopClientId
    client_secret = $ShopClientSecret
}
$tok = Invoke-Api -Method POST -Uri "https://$ShopHost/admin/oauth/access_token" `
    -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 60

if (-not $tok.Ok -or -not $tok.Data.access_token) {
    Write-Log "Shopify token request failed: $(Format-ApiError $tok)" FAIL
    Add-Result 'Shopify token' 'FAIL' "HTTP $($tok.Status)"
    exit 1
}

$script:ShopifyToken = $tok.Data.access_token
Add-Secret $script:ShopifyToken
$tokenMinted = $true
$expiresIn = 0
if ($null -ne $tok.Data.expires_in) { $expiresIn = [int]$tok.Data.expires_in }
$masked = Mask-Secrets $script:ShopifyToken
Write-Log "token acquired: $masked" OK

if ($expiresIn -gt 0) {
    $hours = [math]::Round($expiresIn / 3600, 2)
    Write-Log "token lifetime: ${hours}h ($expiresIn s)" INFO
    if ($expiresIn -lt 86400) {
        Write-Log 'token is short-lived. Re-run this script when the Shopify nodes start returning 401, or schedule it:' WARN
        Write-Log '  schtasks /create /tn "shopify-erpnext setup" /sc daily /st 07:00 /tr "pwsh -NoProfile -File <this script>"' WARN
    }
} else {
    Write-Log 'no expires_in returned - token lifetime unknown, assume short-lived' WARN
}
Add-Result 'Shopify token' 'OK' $masked

# Cache it (with its expiry) so the next run can skip re-minting, which in turn
# keeps the flow byte-identical and avoids restarting Node-RED.
if (-not $script:DryRun) {
    Set-EnvValue $EnvFile 'SHOPIFY_ACCESS_TOKEN' $script:ShopifyToken
    if ($expiresIn -gt 0) {
        Set-EnvValue $EnvFile 'SHOPIFY_TOKEN_EXPIRES' ((Get-Date).AddSeconds($expiresIn).ToString('o'))
    }
    Write-Log 'token cached in .env for the next run' INFO
}

}  # end of the "mint a new token" branch

# ===========================================================================
# 4. ERPNext API keys
# ===========================================================================
Write-Step '4/9' 'ERPNext API credentials'

$erpToken = Get-Cfg 'ERP_API_TOKEN'
function Test-ErpToken([string]$t) {
    if (-not $t) { return $false }
    $r = Invoke-Api -Method GET -Uri "$ErpUrl/api/method/frappe.auth.get_logged_user" `
        -Headers @{ Authorization = "token $t" } -TimeoutSec 20
    return ($r.Ok -and $r.Data.message)
}

if ($erpToken -and (Test-ErpToken $erpToken)) {
    Add-Secret $erpToken
    $who = (Invoke-Api -Method GET -Uri "$ErpUrl/api/method/frappe.auth.get_logged_user" -Headers @{ Authorization = "token $erpToken" } -TimeoutSec 20).Data.message
    Write-Log "existing ERPNext API token from .env authenticates as $who" SKIP
    Add-Result 'ERPNext API token' 'SKIP' 'reused from .env'
} else {
    # Log in with a cookie session to inspect/generate keys.
    $sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $login = Invoke-Api -Method POST -Uri "$ErpUrl/api/method/login" `
        -Body @{ usr = $ErpAdminUser; pwd = $ErpAdminPass } -Session $sess -TimeoutSec 30
    if (-not $login.Ok) {
        Write-Log "ERPNext login failed for $ErpAdminUser : $(Format-ApiError $login)" FAIL
        Add-Result 'ERPNext API token' 'FAIL' "login HTTP $($login.Status)"
        exit 1
    }
    Write-Log "logged in as $ErpAdminUser" OK

    $userInfo = Invoke-Api -Method GET -Uri "$ErpUrl/api/resource/User/$([uri]::EscapeDataString($ErpAdminUser))?fields=%5B%22api_key%22%5D" -Session $sess -TimeoutSec 20
    $hasKey = ($userInfo.Ok -and $userInfo.Data.data.api_key)

    if ($hasKey) {
        Write-Log "user already has an API key ($($userInfo.Data.data.api_key)); its secret cannot be read back" INFO
        Write-Log 'generating a new pair - the previous token stops working (the flow is redeployed in step 7)' WARN
    }

    if (-not (Test-Gate 'generate_keys for the ERPNext user')) {
        Add-Result 'ERPNext API token' 'DRY' 'would generate'
        $erpToken = 'DRY-RUN'
    } else {
        $gen = Invoke-Api -Method POST -Uri "$ErpUrl/api/method/frappe.core.doctype.user.user.generate_keys" `
            -Body @{ user = $ErpAdminUser } -Session $sess -TimeoutSec 30
        if (-not $gen.Ok -or -not $gen.Data.message.api_secret) {
            Write-Log "generate_keys failed: $(Format-ApiError $gen)" FAIL
            Add-Result 'ERPNext API token' 'FAIL' "HTTP $($gen.Status)"
            exit 1
        }
        $erpToken = "$($gen.Data.message.api_key):$($gen.Data.message.api_secret)"
        Add-Secret $erpToken
        Add-Secret $gen.Data.message.api_secret

        # Persist so the next run is a no-op. Prefer the file that already owns
        # the key (this build uses ERPNEXT_API_TOKEN in the parent .env).
        $persistTarget = $EnvFile
        $persistKey = 'ERP_API_TOKEN'
        if ((Test-Path -LiteralPath $BaseEnvFile) -and (Read-EnvFileStrict $BaseEnvFile).Contains('ERPNEXT_API_TOKEN')) {
            $persistTarget = $BaseEnvFile
            $persistKey = 'ERPNEXT_API_TOKEN'
        }
        $lines = [System.Collections.Generic.List[string]](@(Get-Content -LiteralPath $persistTarget))
        $found = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\s*$([regex]::Escape($persistKey))\s*=") { $lines[$i] = "$persistKey=$erpToken"; $found = $true; break }
        }
        if (-not $found) { $lines.Add("$persistKey=$erpToken") }
        [System.IO.File]::WriteAllLines($persistTarget, $lines, [System.Text.UTF8Encoding]::new($false))
        Write-Log "saved $persistKey to $(Split-Path $persistTarget -Leaf)" FIXED
        Add-Result 'ERPNext API token' 'FIXED' 'generated + saved'
    }
}

$ErpHeaders = @{ Authorization = "token $erpToken" }

function Test-ErpAccess {
    $r = Invoke-Api -Method GET -Uri "$ErpUrl/api/method/frappe.auth.get_logged_user" -Headers $ErpHeaders -TimeoutSec 20
    return $r.Ok
}

# ===========================================================================
# DocType meta helpers - the script never guesses a fieldname
# ===========================================================================
# Build a Frappe filter JSON string from a FLAT list of triples:
#   New-FilterJson 'webhook_doctype','=','Delivery Note','webhook_docevent','=','on_submit'
#   -> [["webhook_doctype","=","Delivery Note"],["webhook_docevent","=","on_submit"]]
# Why not nested array literals: PowerShell FLATTENS @(@(..),@(..)) when the
# elements are written one per line, which silently produced a 1-D filter that
# matched nothing (and then every create hit a duplicate-name 409).
function New-FilterJson([string[]]$flat) {
    $rows = @()
    for ($i = 0; $i + 2 -lt $flat.Count; $i += 3) {
        $cells = @($flat[$i], $flat[$i + 1], $flat[$i + 2]) | ForEach-Object {
            ConvertTo-Json -InputObject ([string]$_) -Compress
        }
        $rows += '[' + ($cells -join ',') + ']'
    }
    return '[' + ($rows -join ',') + ']'
}

function Get-DocFieldMap([string]$doctype) {
    $filters = New-FilterJson 'parent', '=', $doctype
    $fields = ConvertTo-Json -Compress -InputObject @('fieldname', 'fieldtype', 'options', 'label', 'reqd')
    $uri = "$ErpUrl/api/resource/DocField?filters=$([uri]::EscapeDataString($filters))&fields=$([uri]::EscapeDataString($fields))&limit_page_length=0&order_by=idx"
    $r = Invoke-Api -Method GET -Uri $uri -Headers $ErpHeaders -TimeoutSec 25
    $map = @{}
    if (-not $r.Ok) { return $map }
    foreach ($f in $r.Data.data) { $map[[string]$f.fieldname] = $f }
    return $map
}

function Test-LinkRecord([string]$doctype, [string]$value) {
    if (-not $value) { return $false }
    $r = Invoke-Api -Method GET -Uri "$ErpUrl/api/resource/$([uri]::EscapeDataString($doctype))/$([uri]::EscapeDataString($value))" -Headers $ErpHeaders -TimeoutSec 20
    return $r.Ok
}

function Get-LinkSample([string]$doctype, [int]$n = 12) {
    $fields = ConvertTo-Json -Compress -InputObject @('name')
    $r = Invoke-Api -Method GET -Uri "$ErpUrl/api/resource/$([uri]::EscapeDataString($doctype))?fields=$([uri]::EscapeDataString($fields))&limit_page_length=$n" -Headers $ErpHeaders -TimeoutSec 20
    if (-not $r.Ok -or -not $r.Data.data) { return '(none)' }
    return (($r.Data.data | ForEach-Object { $_.name }) -join ', ')
}

# Assemble a payload from a desired map, keeping only fieldnames the live
# DocType actually has. Anything dropped is reported, never silently ignored.
function New-PayloadFromMap($fieldMap, $desired, [hashtable]$headers = @{}) {
    $payload = [ordered]@{}
    $skipped = @()
    $assumed = @()
    foreach ($field in $desired.Keys) {
        if ($fieldMap.ContainsKey($field)) { $payload[$field] = $desired[$field] }
        else { $skipped += $field }
    }
    foreach ($h in $headers.Keys) {
        if ($fieldMap.ContainsKey($h)) { $payload[$h] = $headers[$h] } else { $skipped += $h }
    }
    return [pscustomobject]@{ Payload = $payload; Skipped = $skipped }
}

# ===========================================================================
# 5. Shopify Access record
# ===========================================================================
Write-Step '5/9' 'ERPNext: Shopify Access record'

$saFields = Get-DocFieldMap 'Shopify Access'
if ($saFields.Count -eq 0) {
    Write-Log 'could not read the Shopify Access DocType meta - is the `shopify` app installed?' FAIL
    Add-Result 'Shopify Access' 'FAIL' 'DocType meta unavailable'
    $fatal = $true
} else {
    Write-Log ("Shopify Access has {0} fields (names verified live, not guessed)" -f $saFields.Count) INFO

    # Validate the Link targets before writing anything.
    $linkProblems = @()
    if (-not (Test-LinkRecord 'Company' $ErpCompany)) {
        $linkProblems += "ERP_COMPANY '$ErpCompany' is not a Company. Available: $(Get-LinkSample 'Company')"
    }
    if (-not (Test-LinkRecord 'Account' $ErpBankAccount)) {
        $linkProblems += "ERP_BANK_ACCOUNT '$ErpBankAccount' is not an Account. Bank/Cash options: $(Get-LinkSample 'Account' 40)"
    }
    if ($linkProblems.Count -gt 0) {
        foreach ($p in $linkProblems) { Write-Log $p FAIL }
        Add-Result 'Shopify Access' 'FAIL' 'invalid Link value(s)'
        $fatal = $true
    }
}

if (-not $fatal) {
    $shopUrl = "https://$ShopHost/admin/api/$ShopApiVersion/"
    $desired = [ordered]@{
        link_name       = $ErpCompany           # "Company Name"
        shopify_account = 'Main'                # Select: Main/Secondary/Third
        app_type        = 'Custom'
        shop_domain_url = "https://$ShopHost"    # "Domain URL"
        api_key         = $ShopClientId
        secret_key      = $ShopClientSecret
        access_token    = $script:ShopifyToken
        updated_version = $ShopApiVersion        # "Shopify API Version"
        company         = $ErpCompany
        bank_account    = $ErpBankAccount
        shopify_url     = $shopUrl               # autoname = field:shopify_url
    }
    $built = New-PayloadFromMap -fieldMap $saFields -desired $desired
    if ($built.Skipped.Count -gt 0) { Write-Log ("fields not present in this DocType, skipped: " + ($built.Skipped -join ', ')) WARN }
    Write-Log "assumed fieldnames (verified against meta): $(($built.Payload.Keys) -join ', ')" INFO

    # find existing by domain
    $filters = New-FilterJson 'shop_domain_url', '=', "https://$ShopHost"
    $existing = Invoke-Api -Method GET -Uri "$ErpUrl/api/resource/Shopify%20Access?filters=$([uri]::EscapeDataString($filters))&limit_page_length=1" -Headers $ErpHeaders -TimeoutSec 20
    $existingName = $null
    if ($existing.Ok -and $existing.Data.data.Count -gt 0) { $existingName = $existing.Data.data[0].name }

    if ($existingName -and $existingName.Count -ge 0) {
        # Compare before writing so an unchanged record is reported [SKIP]
        # instead of being rewritten (and reported FIXED) on every run.
        $fieldList = ConvertTo-Json -Compress -InputObject @($built.Payload.Keys)
        $cmpUri = "$ErpUrl/api/resource/Shopify%20Access?filters=$([uri]::EscapeDataString($filters))&fields=$([uri]::EscapeDataString($fieldList))&limit_page_length=1"
        $cur = Invoke-Api -Method GET -Uri $cmpUri -Headers $ErpHeaders -TimeoutSec 20
        $diffs = @()
        if ($cur.Ok -and @($cur.Data.data).Count -gt 0) {
            $row = $cur.Data.data[0]
            foreach ($k in $built.Payload.Keys) {
                $oldV = [string](Get-Obj $row $k '')
                $newV = [string]$built.Payload[$k]
                if ($oldV -ne $newV) { $diffs += $k }
            }
        } else { $diffs = @('(could not read current record)') }

        if ($diffs.Count -eq 0) {
            Write-Log "Shopify Access '$existingName' already matches .env" SKIP
            Add-Result 'Shopify Access' 'SKIP' 'already matches'
        }
        elseif (Test-Gate "update Shopify Access '$existingName'") {
            # The docname IS a URL ("https://<shop>/admin/api/<ver>/"), so it
            # contains slashes and cannot be addressed as .../Shopify Access/<name>
            # (Werkzeug splits it into path segments -> 404). frappe.client.set_value
            # takes the name in the body instead, and accepts a dict of fields.
            $setBody = ConvertTo-Json -Depth 8 -InputObject @{
                doctype   = 'Shopify Access'
                name      = $existingName
                fieldname = $built.Payload
            }
            $upd = Invoke-Api -Method POST -Uri "$ErpUrl/api/method/frappe.client.set_value" `
                -Headers $ErpHeaders -Body $setBody -ContentType 'application/json' -TimeoutSec 30
            if ($upd.Ok) {
                Write-Log "updated Shopify Access '$existingName' (fields: $($diffs -join ', '))" FIXED
                Add-Result 'Shopify Access' 'FIXED' "updated: $($diffs -join ', ')"
            } else {
                Write-Log "update failed: $(Format-ApiError $upd)" FAIL
                Add-Result 'Shopify Access' 'FAIL' "HTTP $($upd.Status)"
                $fatal = $true
            }
        }
    } else {
        if (Test-Gate 'create Shopify Access') {
            $new = Invoke-Api -Method POST -Uri "$ErpUrl/api/resource/Shopify%20Access" `
                -Headers $ErpHeaders -Body ($built.Payload | ConvertTo-Json -Depth 5) -ContentType 'application/json' -TimeoutSec 30
            if ($new.Ok) { Write-Log "created Shopify Access '$($new.Data.data.name)'" FIXED; Add-Result 'Shopify Access' 'FIXED' 'created' }
            else { Write-Log "create failed: $(Format-ApiError $new)" FAIL; Add-Result 'Shopify Access' 'FAIL' "HTTP $($new.Status)"; $fatal = $true }
        }
    }
}

# ===========================================================================
# 6. Shopify Settings (single doctype)
# ===========================================================================
Write-Step '6/9' 'ERPNext: Shopify Settings'

# IMPORTANT: this build installs the `shopify-shrdc` app, which has ONLY
# `Shopify Access` and `Shopify Link`. There is no `Shopify Settings` single
# doctype (that belongs to a different Shopify app). We therefore detect it at
# runtime: populate it fully when present, otherwise say so and continue.
$ssFields = Get-DocFieldMap 'Shopify Settings'
if ($ssFields.Count -eq 0) {
    Write-Log 'this site has no `Shopify Settings` DocType - skipping (not a failure)' SKIP
    Write-Log 'the installed app (shopify-shrdc) stores store config in `Shopify Access` (step 5)' INFO
    Add-Result 'Shopify Settings' 'SKIP' 'DocType not installed in this app'

    # `Shopify Link` is the app's enable/link page; set the flag if a row exists.
    $sl = Invoke-Api -Method GET -Uri "$ErpUrl/api/resource/Shopify%20Link?limit_page_length=1" -Headers $ErpHeaders -TimeoutSec 20
    if ($sl.Ok -and $sl.Data.data.Count -gt 0) {
        $row = $sl.Data.data[0].name
        if (Test-Gate "enable Shopify on Shopify Link '$row'") {
            $en = Invoke-Api -Method PUT -Uri "$ErpUrl/api/resource/Shopify%20Link/$([uri]::EscapeDataString($row))" `
                -Headers $ErpHeaders -Body (@{ shopify_enable = 1 } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 20
            if ($en.Ok) { Write-Log "Shopify Link '$row' shopify_enable=1" FIXED } else { Write-Log "could not enable Shopify Link: $(Format-ApiError $en)" WARN }
        }
    } else {
        Write-Log 'no Shopify Link row present - nothing to enable' INFO
    }
} else {
    # Generic path for sites that DO have it. Field names are resolved from the
    # live meta; anything missing is reported instead of guessed.
    Write-Log ("Shopify Settings has {0} fields" -f $ssFields.Count) INFO

    $desired = [ordered]@{
        enable_shopify                     = 1
        app_type                           = 'Private'
        shop_url                           = $ShopHost
        api_key                            = $ShopClientId
        password                           = $script:ShopifyToken
        shared_secret                      = $ShopClientSecret
        customer_group                     = 'All Customer Groups'
        company                            = $ErpCompany
        cost_center                        = $ErpCostCenter
        cash_bank_account                  = $ErpCashBank
        price_list                         = $ErpPriceList
        warehouse                          = $ErpWarehouse
        update_price_in_erpnext_price_list = 1
        sales_order_series                 = 'SAL-ORD-.YYYY.-'
        sync_delivery_note                 = 1
        delivery_note_series               = 'MAT-DN-.YYYY.-'
        sync_sales_invoice                 = 1
        sales_invoice_series               = 'ACC-SINV-.YYYY.-'
    }
    $built = New-PayloadFromMap -fieldMap $ssFields -desired $desired
    if ($built.Skipped.Count -gt 0) { Write-Log ("fields not present, skipped: " + ($built.Skipped -join ', ')) WARN }
    if ($ssFields.ContainsKey('taxes') -and $ssFields['taxes'].options) {
        $built.Payload['taxes'] = @(@{ account_head = $ErpTaxAccount; description = 'Default tax' })
    } elseif ($ssFields.ContainsKey('tax_account')) {
        $built.Payload['tax_account'] = $ErpTaxAccount
    } else {
        Write-Log 'no tax row field found on Shopify Settings - tax mapping skipped' WARN
    }

    if (Test-Gate 'save Shopify Settings') {
        $save = Invoke-Api -Method POST -Uri "$ErpUrl/api/resource/Shopify%20Settings" `
            -Headers $ErpHeaders -Body ($built.Payload | ConvertTo-Json -Depth 6) -ContentType 'application/json' -TimeoutSec 30
        if (-not $save.Ok) {
            # single doctypes are often updated with PUT
            $save = Invoke-Api -Method PUT -Uri "$ErpUrl/api/resource/Shopify%20Settings" `
                -Headers $ErpHeaders -Body ($built.Payload | ConvertTo-Json -Depth 6) -ContentType 'application/json' -TimeoutSec 30
        }
        if ($save.Ok) { Write-Log 'Shopify Settings saved' FIXED; Add-Result 'Shopify Settings' 'FIXED' 'saved' }
        else { Write-Log "saving Shopify Settings failed: $(Format-ApiError $save)" FAIL; Add-Result 'Shopify Settings' 'FAIL' "HTTP $($save.Status)" }
    }
}

# ===========================================================================
# 7. Node-RED flow: patch credentials + URLs, then deploy
# ===========================================================================
Write-Step '7/9' 'Node-RED flow: credentials, URLs, deploy'

$erpNodeNames = @(
    'GET Sales Order', 'TRANSFORM Sales Order', 'SAVE Sales Order', 'SUBMIT Sales Order',
    'CREATE Sales Invoice', 'SAVE Sales Invoice', 'SUBMIT Sales Invoice',
    'GET delivery note', 'EXTRACT ERP Stock Entry', 'EXTRACT ERP Stock Reconciliation'
)
$shopNodeNames = @(
    'GET fulfillment order', 'CREATE fulfillment order', 'GET Shopify Locations',
    'FIND Shopify SKU', 'FIND SKU'
)
$httpInMap = [ordered]@{
    'delivery note'       = '/delivery-note'
    'stock entry'         = '/stock-entry'
    'stock reconciliation' = '/stock-recon'
}

function Set-NodeHeader($node, [string]$key, [string]$value) {
    $list = @()
    if ($node.PSObject.Properties.Name -contains 'headers' -and $node.headers) {
        $list = @($node.headers | Where-Object { $_ })
    }
    $found = $false
    foreach ($h in $list) {
        if ($h.keyValue -eq $key) { $h.valueValue = $value; $found = $true }
    }
    if (-not $found) {
        $list += [pscustomobject]@{ keyType = 'other'; keyValue = $key; valueType = 'other'; valueValue = $value }
    }
    $node | Add-Member -NotePropertyName headers -NotePropertyValue $list -Force
}

$flowRaw = Get-Content -LiteralPath $FlowJsonPath -Raw
$backup = "$FlowJsonPath.bak.$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
if (Test-Gate "back up $FlowJsonPath") {
    Copy-Item -LiteralPath $FlowJsonPath -Destination $backup -Force
    Write-Log "backup: $(Split-Path $backup -Leaf)" OK
}

# NOTE: read through the PIPELINE, not -InputObject. Windows PowerShell 5.1
# returns a JSON array from -InputObject as one nested object, so the flow would
# be seen as a single node and every per-node patch would silently do nothing.
$flow = @(Get-Content -LiteralPath $FlowJsonPath -Raw | ConvertFrom-Json)
if ($flow.Count -gt 0 -and $flow[0] -is [array]) { $flow = @($flow[0]) }
$patchedErp = 0; $patchedShop = 0; $patchedIn = 0
$missingNodes = @()
$urlRewrites = 0

foreach ($node in $flow) {
    switch ($node.type) {
        'http request' {
            if ($erpNodeNames -contains $node.name) {
                Set-NodeHeader $node 'Authorization' "token $erpToken"
                Set-NodeHeader $node 'Content-Type' 'application/json'
                $patchedErp++
            }
            if ($shopNodeNames -contains $node.name) {
                Set-NodeHeader $node 'X-Shopify-Access-Token' $script:ShopifyToken
                Set-NodeHeader $node 'Content-Type' 'application/json'
                $patchedShop++
            }
            # rewrite ERPNext URLs (localhost is wrong from inside Node-RED)
            if ($node.url -match '^https?://(localhost|127\.0\.0\.1):8000') {
                $node.url = ($node.url -replace '^https?://(localhost|127\.0\.0\.1):8000', $ErpInternalUrl)
                $urlRewrites++
            }
            # rewrite the Shopify base for the configured store + API version
            if ($node.url -match 'myshopify\.com/admin/api/') {
                $node.url = ($node.url -replace 'https://[A-Za-z0-9-]+\.myshopify\.com/admin/api/[0-9A-Za-z-]+', "https://$ShopHost/admin/api/$ShopApiVersion")
                $urlRewrites++
            }
        }
        'http in' {
            $name = ([string]$node.name).ToLowerInvariant()
            foreach ($key in $httpInMap.Keys) {
                if ($name -like "*$key*") { $node.url = $httpInMap[$key]; $patchedIn++; break }
            }
        }
    }
}

foreach ($n in $erpNodeNames) { if (-not ($flow | Where-Object { $_.name -eq $n })) { $missingNodes += "ERP: $n" } }
foreach ($n in $shopNodeNames) { if (-not ($flow | Where-Object { $_.name -eq $n })) { $missingNodes += "Shopify: $n" } }

Write-Log "ERPNext http nodes patched: $patchedErp/$($erpNodeNames.Count)" $(if ($patchedErp -eq $erpNodeNames.Count) { 'OK' } else { 'WARN' })
Write-Log "Shopify http nodes patched: $patchedShop/$($shopNodeNames.Count)" $(if ($patchedShop -eq $shopNodeNames.Count) { 'OK' } else { 'WARN' })
Write-Log "http-in endpoints normalised: $patchedIn/3" $(if ($patchedIn -ge 3) { 'OK' } else { 'WARN' })
Write-Log "URLs rewritten to the live stack: $urlRewrites" INFO
if ($missingNodes.Count -gt 0) { Write-Log ("nodes not found in the flow: " + ($missingNodes -join '; ')) WARN }

# Defensive: some exports ship an empty Shopify token in a function node that
# then overwrites the header the http node set (this is the build-flows.py bug).
$emptyHdr = [regex]::Matches($flowRaw, '"X-Shopify-Access-Token"\s*:\s*""').Count
if ($emptyHdr -gt 0) { Write-Log "found $emptyHdr empty X-Shopify-Access-Token literal(s) in function nodes - rebuild with build-flows.py to fix" WARN }

$flowJson = ConvertTo-Json -InputObject $flow -Depth 40 -Compress

# Node-RED persists a deploy by writing /data/flows.json.$$$ then renaming it
# over /data/flows.json. When that file is a BIND MOUNT from a Windows host,
# Docker Desktop fails the rename with EBUSY, so the Admin API answers 400 and
# the editor's own Deploy button cannot work either. Detect the condition
# instead of guessing at it: writing the host file + restarting is equivalent.
function Test-FlowBindMounted {
    param([string]$Container)
    if (-not $Container) { return $false }
    $names = @(& docker ps -a --format '{{.Names}}' 2>$null)
    if ($names -notcontains $Container) { return $false }
    $mounts = (& docker inspect $Container --format '{{range .Mounts}}{{.Type}} {{.Destination}}{{println}}{{end}}' 2>$null) -join "`n"
    return ($mounts -match '(?m)^bind\s+/data/flows\.json\s*$')
}

$flowBindMounted = Test-FlowBindMounted -Container $NodeRedContainer

if (-not $SkipFlowDeploy) {
    if (-not (Test-Gate "deploy $($flow.Count) nodes to Node-RED")) {
        # -WhatIf handled below
    } elseif ($flowBindMounted) {
        Write-Log '/data/flows.json is a bind mount from the Windows host - the Admin API deploy cannot rename it (EBUSY)' WARN
        Write-Log 'the Node-RED editor "Deploy" button cannot work in this configuration either' WARN
        Write-Log "using the equivalent path: write $([System.IO.Path]::GetFileName($FlowJsonPath)) on the host, restart $NodeRedContainer" INFO

        # Writing + restarting Node-RED is only justified when the flow actually
        # changed (a new token, a new URL). Otherwise a re-run would bounce the
        # bridge on every invocation.
        $existingRaw = ''
        if (Test-Path -LiteralPath $FlowJsonPath) { $existingRaw = Get-Content -LiteralPath $FlowJsonPath -Raw }
        $flowChanged = ($existingRaw.Trim() -ne $flowJson.Trim())

        if (-not $flowChanged) {
            Write-Log 'deployed flow already matches the patched flow - nothing to write' SKIP
            Add-Result 'Flow deploy' 'SKIP' 'already up to date'
        }
        elseif (Test-Gate "write $FlowJsonPath and restart $NodeRedContainer") {
            [System.IO.File]::WriteAllText($FlowJsonPath, $flowJson, (New-Object System.Text.UTF8Encoding($false)))
            Write-Log 'wrote the patched flow to the host file' OK

            & docker restart $NodeRedContainer | Out-Null
            Write-Log "restarted $NodeRedContainer" OK

            $deadline = (Get-Date).AddSeconds(90)
            $after = $null
            do {
                Start-Sleep -Seconds 3
                $after = Invoke-Api -Method GET -Uri "$NodeRedUrl/flows" -TimeoutSec 6
            } while ((Get-Date) -lt $deadline -and -not $after.Ok)

            if ($after.Ok) {
                $liveCount = @($after.Data).Count
                if ($liveCount -ge ($flow.Count - 2)) {
                    Write-Log "runtime reports $liveCount nodes" OK
                    Add-Result 'Flow deploy' 'FIXED' "$liveCount nodes via host file + restart"
                } else {
                    Write-Log "runtime reports only $liveCount nodes (expected ~$($flow.Count))" FAIL
                    Add-Result 'Flow deploy' 'FAIL' "runtime $liveCount nodes"
                    $fatal = $true
                }
            } else {
                Write-Log 'Node-RED did not answer after the restart' FAIL
                Add-Result 'Flow deploy' 'FAIL' 'no response after restart'
                $fatal = $true
            }
        }
    } else {
        $deploy = Invoke-Api -Method POST -Uri "$NodeRedUrl/flows" -Body $flowJson -ContentType 'application/json' -TimeoutSec 45
        if ($deploy.Ok) {
            Write-Log "deployed $($flow.Count) nodes to Node-RED" FIXED
            Add-Result 'Flow deploy' 'FIXED' "$($flow.Count) nodes via admin API"
            $after = Invoke-Api -Method GET -Uri "$NodeRedUrl/flows" -TimeoutSec 15
            if ($after.Ok) { Write-Log "runtime now reports $(@($after.Data).Count) nodes" INFO }
        } else {
            Write-Log "deploy failed: $(Format-ApiError $deploy)" FAIL
            Write-Log "restore with: Copy-Item '$backup' '$FlowJsonPath' -Force" WARN
            Add-Result 'Flow deploy' 'FAIL' "HTTP $($deploy.Status)"
            $fatal = $true
        }
    }
} else {
    Write-Log 'flow patched but not deployed (-SkipFlowDeploy)' SKIP
    Add-Result 'Flow deploy' 'SKIP' '-SkipFlowDeploy'
}

# ===========================================================================
# 8. ERPNext webhooks
# ===========================================================================
Write-Step '8/9' 'ERPNext webhooks'

$whFields = Get-DocFieldMap 'Webhook'
$whHeaderFields = Get-DocFieldMap 'Webhook Header'
$whDataFields = Get-DocFieldMap 'Webhook Data'

if ($whFields.Count -eq 0) {
    Write-Log 'could not read the Webhook DocType meta' FAIL
    Add-Result 'Webhooks' 'FAIL' 'meta unavailable'
} else {
    $base = $script:PublicUrl.TrimEnd('/')
    $specs = @(
        @{
            Doctype = 'Delivery Note'; Event = 'on_submit'; Path = '/delivery-note'
            Body    = '{"delivery_note": "{{ doc.name }}"}'
            Data    = @(@{ fieldname = 'name'; key = 'delivery_note' })
        },
        @{
            Doctype = 'Stock Entry'; Event = 'on_submit'; Path = '/stock-entry'
            Body    = '{"doctype": "{{ doc.doctype }}", "name": "{{ doc.name }}", "stock_entry_type": "{{ doc.stock_entry_type }}"}'
            Data    = @(
                @{ fieldname = 'doctype'; key = 'doctype' }
                @{ fieldname = 'name'; key = 'name' }
                @{ fieldname = 'stock_entry_type'; key = 'stock_entry_type' }
            )
        },
        @{
            Doctype = 'Stock Reconciliation'; Event = 'on_submit'; Path = '/stock-recon'
            Body    = '{"doctype": "{{ doc.doctype }}", "name": "{{ doc.name }}", "posting_date": "{{ doc.posting_date }}"}'
            Data    = @(
                @{ fieldname = 'doctype'; key = 'doctype' }
                @{ fieldname = 'name'; key = 'name' }
                @{ fieldname = 'posting_date'; key = 'posting_date' }
            )
        }
    )

    # --- preferred path: write the webhooks from INSIDE the bench ------------
    # The generic /api/resource endpoint creates the child rows (Webhook Header
    # / Webhook Data) with an EMPTY parent on this Frappe build, so the headers
    # silently end up as blank rows. The server-side document API does not have
    # that problem - it is the same technique the build's own
    # sandbox/scripts/ai-fix-wire-webhooks.sh uses.
    $benchOk = $false
    $useBench = $false
    if ($BenchContainer) {
        $names = @(& docker ps -a --format '{{.Names}}' 2>$null)
        $useBench = ($names -contains $BenchContainer)
    }

    # Decide whether anything needs writing, so a re-run is a no-op.
    $webhooksNeedWrite = $true
    if ($useBench) {
        $vw = Invoke-Api -Method GET -Uri "$ErpUrl/api/resource/Webhook?fields=%5B%22webhook_doctype%22%2C%22request_url%22%2C%22enabled%22%2C%22webhook_json%22%5D&limit_page_length=10" -Headers $ErpHeaders -TimeoutSec 20
        if ($vw.Ok) {
            $cur = @{}
            foreach ($row in @($vw.Data.data)) { $cur[[string]$row.webhook_doctype] = $row }
            $webhooksNeedWrite = $false
            foreach ($s in $specs) {
                $row = $cur[$s.Doctype]
                if (-not $row) { $webhooksNeedWrite = $true; break }
                if ("$($row.request_url)" -ne "$base$($s.Path)") { $webhooksNeedWrite = $true; break }
                if (-not [bool]$row.enabled) { $webhooksNeedWrite = $true; break }
                if ((([string]$row.webhook_json) -replace '\s', '') -ne ($s.Body -replace '\s', '')) { $webhooksNeedWrite = $true; break }
            }
            if (-not $webhooksNeedWrite) {
                foreach ($s in $specs) {
                    Write-Log "webhook $($s.Doctype) already correct (url, enabled, JSON body)" SKIP
                    Add-Result "Webhook $($s.Doctype)" 'SKIP' 'already matches'
                }
                # Still surface the header limitation on a no-op run, otherwise
                # "all good" would be a lie about X-Webhook-Secret.
                if ($WebhookSecret) {
                    $hdrMissing = @($vw.Data.data | Where-Object { @($_.webhook_headers | Where-Object { $_.key }).Count -eq 0 })
                    if ($hdrMissing.Count -gt 0) {
                        Write-Log "X-Webhook-Secret is not stored on $($hdrMissing.Count)/3 webhooks - this Frappe build saves Webhook Header rows with an empty parent" WARN
                        Add-Result 'Webhook headers' 'WARN' "not persisted on $($hdrMissing.Count)/3"
                    } else {
                        Add-Result 'Webhook headers' 'PASS' 'X-Webhook-Secret present'
                    }
                }
                $benchOk = $true
            }
        }
    }

    if ($useBench -and $webhooksNeedWrite -and -not $script:DryRun -and (Test-Gate 'write webhooks via bench execute')) {
        $specPy = ($specs | ForEach-Object {
                "    {'label': '$($_.Doctype) Webhook', 'doctype': '$($_.Doctype)', 'path': '$($_.Path)', 'json': '$($_.Body)'},"
            }) -join "`n"

        $py = @'
import frappe

BASE = "__BASE__"
SECRET = "__SECRET__"
SPECS = [
__SPECS__
]


def run():
    for s in SPECS:
        name = frappe.db.get_value(
            "Webhook",
            {"webhook_doctype": s["doctype"], "webhook_docevent": "on_submit"},
            "name",
        )
        action = "updated"
        if name:
            doc = frappe.get_doc("Webhook", name)
        else:
            doc = frappe.new_doc("Webhook")
            doc.name = s["label"]
            action = "created"

        doc.webhook_doctype = s["doctype"]
        doc.webhook_docevent = "on_submit"
        doc.request_url = BASE + s["path"]
        doc.request_method = "POST"
        doc.request_structure = "JSON"
        doc.webhook_json = s["json"]
        doc.enabled = 1
        doc.enable_security = 0
        # child tables are rebuilt from scratch, so stale/blank rows go away
        doc.set("webhook_data", [])
        doc.set("webhook_headers", [])
        doc.append("webhook_headers", {"key": "Content-Type", "value": "application/json"})
        if SECRET:
            doc.append("webhook_headers", {"key": "X-Webhook-Secret", "value": SECRET})
        doc.flags.ignore_permissions = True
        doc.save()
        print("MARK_WH %s | %s | %s" % (action, s["doctype"], doc.request_url))
    frappe.db.commit()
    frappe.clear_cache()
'@
        $py = $py.Replace('__BASE__', $base).Replace('__SECRET__', $WebhookSecret).Replace('__SPECS__', $specPy)

        $tmpPy = Join-Path $env:TEMP '_setup_webhooks.py'
        [System.IO.File]::WriteAllText($tmpPy, $py, (New-Object System.Text.UTF8Encoding($false)))
        $destPy = '/home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc/_setup_webhooks.py'
        # Array splatting, not an inline string: `& docker exec ... bash -lc "..."`
        # gets re-split by PowerShell's native argument handling and docker then
        # sees 'barcode_shrdc._setup_webhooks.run' as a docker subcommand.
        & docker @('cp', $tmpPy, "${BenchContainer}:$destPy") 2>$null | Out-Null
        $execArgs = @('exec', '-u', 'frappe', $BenchContainer, 'bash', '-lc',
            "cd /home/frappe/frappe-bench && bench --site $siteName execute barcode_shrdc._setup_webhooks.run")
        $out = ((& docker @execArgs 2>&1) -join "`n")
        & docker @('exec', '-u', 'frappe', $BenchContainer, 'bash', '-lc', "rm -f $destPy") 2>$null | Out-Null

        $marks = [regex]::Matches($out, 'MARK_WH ([a-z]+) \| ([^|]+)\| (.+)')
        if ($marks.Count -ge 3) {
            foreach ($m in $marks) {
                $action = $m.Groups[1].Value
                $dt = $m.Groups[2].Value.Trim()
                $turl = $m.Groups[3].Value.Trim()
                Write-Log "webhook $dt -> $turl ($action; URL, method, JSON body, enabled)" FIXED
                Add-Result "Webhook $dt" 'FIXED' "$action via bench"
            }

            # Verify a read-back rather than trusting the save(): on this Frappe
            # build the Webhook Header child rows are stored with an empty
            # parent and come back blank, so the X-Webhook-Secret header must be
            # reported as NOT applied instead of silently claimed.
            $vw2 = Invoke-Api -Method GET -Uri "$ErpUrl/api/resource/Webhook?fields=%5B%22webhook_doctype%22%2C%22webhook_headers%22%5D&limit_page_length=10" -Headers $ErpHeaders -TimeoutSec 20
            $hdrOk = $true
            if ($vw2.Ok -and $WebhookSecret) {
                foreach ($row in @($vw2.Data.data)) {
                    if (@($row.webhook_headers | Where-Object { $_.key }).Count -eq 0) { $hdrOk = $false }
                }
            }
            if (-not $hdrOk) {
                Write-Log 'the X-Webhook-Secret header did NOT persist - this Frappe build saves Webhook Header rows with an empty parent' WARN
                Write-Log 'the flow does not require it; drop WEBHOOK_SECRET from .env or fix the child table server-side' WARN
                Add-Result 'Webhook headers' 'WARN' 'X-Webhook-Secret not persisted by this build'
            } else {
                Write-Log 'X-Webhook-Secret header verified on all three webhooks' OK
                Add-Result 'Webhook headers' 'PASS' 'X-Webhook-Secret present'
            }
            $benchOk = $true
        } else {
            Write-Log "bench-based webhook write did not report success: $(($out -split "`n" | Select-Object -Last 6) -join ' / ')" WARN
            Write-Log 'falling back to the REST writer' INFO
        }
    }

    # --- fallback: REST writer (works where child rows marshal correctly) ----
    if (-not $benchOk) {
    foreach ($spec in $specs) {
        $url = "$base$($spec.Path)"
        $label = "$($spec.Doctype).$($spec.Event)"

        $payload = [ordered]@{}
        foreach ($f in @('webhook_doctype', 'webhook_docevent', 'request_url', 'request_method', 'request_structure', 'enabled')) {
            if ($whFields.ContainsKey($f)) { $payload[$f] = $null }
        }
        $payload['webhook_doctype'] = $spec.Doctype
        $payload['webhook_docevent'] = $spec.Event
        $payload['request_url'] = $url
        $payload['request_method'] = 'POST'
        $payload['request_structure'] = 'JSON'
        $payload['enabled'] = 1

        # headers
        if ($whFields.ContainsKey('webhook_headers') -and $whHeaderFields.Count -gt 0) {
            $headers = @(@{ key = 'Content-Type'; value = 'application/json' })
            if ($WebhookSecret) { $headers += @{ key = 'X-Webhook-Secret'; value = $WebhookSecret } }
            $payload['webhook_headers'] = $headers
        }
        # native signature support, off: we use the explicit header above
        if ($whFields.ContainsKey('enable_security')) { $payload['enable_security'] = 0 }

        # Body. In ERPNext v16 the controller does, for request_structure=JSON:
        #     validate_template(self.webhook_json); self.webhook_data = []
        # i.e. a JSON webhook CLEARS webhook_data and renders the Jinja body from
        # webhook_json. Writing webhook_data rows instead produces an empty body
        # with no error - which is exactly what happened before this was fixed.
        if ($whFields.ContainsKey('webhook_json') -and $spec.Body) {
            $payload['webhook_json'] = $spec.Body
        } elseif ($whFields.ContainsKey('webhook_data') -and $whDataFields.Count -gt 0) {
            $rows = @()
            foreach ($d in $spec.Data) {
                $row = @{}
                if ($whDataFields.ContainsKey('fieldname')) { $row['fieldname'] = $d.fieldname }
                if ($whDataFields.ContainsKey('key')) { $row['key'] = $d.key }
                if ($row.Count -gt 0) { $rows += $row }
            }
            $payload['webhook_data'] = $rows
        }

        # NB: an array of arrays, built explicitly. `@(, @(...), @(...))` adds a
        # spurious nesting level and the filter then matches nothing.
        $filters = New-FilterJson 'webhook_doctype', '=', $spec.Doctype, 'webhook_docevent', '=', $spec.Event
        $found = Invoke-Api -Method GET -Uri "$ErpUrl/api/resource/Webhook?filters=$([uri]::EscapeDataString($filters))&fields=%5B%22name%22%2C%22request_url%22%2C%22enabled%22%2C%22webhook_headers%22%2C%22webhook_json%22%5D&limit_page_length=1" -Headers $ErpHeaders -TimeoutSec 20

        $existingName = $null
        $existingUrl = $null
        $existingEnabled = $false
        $secretOk = $true
        $bodyOk = $true
        if ($found.Ok -and @($found.Data.data).Count -gt 0) {
            $existingName = $found.Data.data[0].name
            $existingUrl = $found.Data.data[0].request_url
            $existingEnabled = [bool]$found.Data.data[0].enabled
            # The URL can be right while the secret header is missing - compare
            # the headers too, otherwise a first run against pre-existing
            # webhooks would skip and never add X-Webhook-Secret.
            if ($WebhookSecret) {
                $hdrRows = @($found.Data.data[0].webhook_headers)
                $secretOk = (@($hdrRows | Where-Object { $_.key -eq 'X-Webhook-Secret' -and $_.value -eq $WebhookSecret }).Count -gt 0)
            }
            # and the body: a webhook with the right URL but an empty
            # webhook_json silently posts '{}'
            if ($whFields.ContainsKey('webhook_json')) {
                $existingJson = [string]$found.Data.data[0].webhook_json
                $bodyOk = (($existingJson -replace '\s', '') -eq ($spec.Body -replace '\s', ''))
            }
        }

        if ($existingName -and $existingUrl -eq $url -and $existingEnabled -and $secretOk -and $bodyOk) {
            Write-Log "webhook $label -> $url already correct" SKIP
            Add-Result "Webhook $($spec.Doctype)" 'SKIP' 'up to date'
            continue
        }
        if ($existingName -and -not $secretOk) {
            Write-Log "webhook $label exists but is missing the X-Webhook-Secret header - updating" INFO
        }
        if ($existingName -and -not $bodyOk) {
            Write-Log "webhook $label exists but its body template is empty or different - updating" INFO
        }

        $body = $payload | ConvertTo-Json -Depth 6
        if ($existingName) {
            if (Test-Gate "update webhook '$existingName'") {
                $upd = Invoke-Api -Method PUT -Uri "$ErpUrl/api/resource/Webhook/$([uri]::EscapeDataString($existingName))" -Headers $ErpHeaders -Body $body -ContentType 'application/json' -TimeoutSec 30
                if ($upd.Ok) { Write-Log "webhook $label updated -> $url" FIXED; Add-Result "Webhook $($spec.Doctype)" 'FIXED' 'updated' }
                else { Write-Log "webhook $label update failed: $(Format-ApiError $upd)" FAIL; Add-Result "Webhook $($spec.Doctype)" 'FAIL' "HTTP $($upd.Status)" }
            }
        } else {
            if (Test-Gate "create webhook for $label") {
                # Webhook.autoname is "prompt": a name must be supplied.
                $payload['name'] = "$($spec.Doctype) Webhook"
                $new = Invoke-Api -Method POST -Uri "$ErpUrl/api/resource/Webhook" -Headers $ErpHeaders `
                    -Body ($payload | ConvertTo-Json -Depth 6) -ContentType 'application/json' -TimeoutSec 30
                if ($new.Ok) { Write-Log "webhook $label created -> $url" FIXED; Add-Result "Webhook $($spec.Doctype)" 'FIXED' 'created' }
                else { Write-Log "webhook $label create failed: $(Format-ApiError $new)" FAIL; Add-Result "Webhook $($spec.Doctype)" 'FAIL' "HTTP $($new.Status)" }
            }
        }
    }
    }   # end of the REST fallback path
}

# ===========================================================================
# 9. smoke tests
# ===========================================================================
Write-Step '9/9' 'Smoke tests'

# a) ERPNext auth
$erpAuth = Invoke-Api -Method GET -Uri "$ErpUrl/api/method/frappe.auth.get_logged_user" -Headers $ErpHeaders -TimeoutSec 20
if ($erpAuth.Ok) {
    Write-Log "ERPNext auth OK (user: $($erpAuth.Data.message | ConvertTo-Json -Compress))" OK
    Add-Result 'ERPNext auth' 'PASS' ''
} else { Write-Log "ERPNext auth failed: $(Format-ApiError $erpAuth)" FAIL; Add-Result 'ERPNext auth' 'FAIL' "HTTP $($erpAuth.Status)" }

# b) Shopify token
$shopCheck = Invoke-Api -Method GET -Uri "https://$ShopHost/admin/api/$ShopApiVersion/shop.json" `
    -Headers @{ 'X-Shopify-Access-Token' = $script:ShopifyToken } -TimeoutSec 30
if ($shopCheck.Ok) {
    Write-Log "Shopify token OK (shop: $($shopCheck.Data.shop.name))" OK
    Add-Result 'Shopify auth' 'PASS' $shopCheck.Data.shop.domain
} else { Write-Log "Shopify token rejected: $(Format-ApiError $shopCheck)" FAIL; Add-Result 'Shopify auth' 'FAIL' "HTTP $($shopCheck.Status)" }

# c) Node-RED endpoints through the public URL
$hookHeaders = @{}
if ($WebhookSecret) { $hookHeaders['X-Webhook-Secret'] = $WebhookSecret }
else { $hookHeaders['ngrok-skip-browser-warning'] = '1' }

foreach ($path in @('/delivery-note', '/stock-entry', '/stock-recon')) {
    $r = Invoke-Api -Method POST -Uri "$($script:PublicUrl)$path" -Headers $hookHeaders -Body '{}' -ContentType 'application/json' -TimeoutSec 40
    # a 404 means the flow is not deployed; anything else means it routed
    if ($r.Status -ne 0 -and $r.Status -ne 404) {
        Write-Log "PUBLIC POST $path -> $($r.Status)" OK
        Add-Result "Endpoint $path" 'PASS' "HTTP $($r.Status)"
    } else {
        Write-Log "PUBLIC POST $path -> $($r.Status) (flow not routed?)" FAIL
        Add-Result "Endpoint $path" 'FAIL' "HTTP $($r.Status)"
    }
}

# ===========================================================================
# summary
# ===========================================================================
Write-Host ''
Write-Host ('=' * 74) -ForegroundColor Cyan
Write-Host '  SUMMARY' -ForegroundColor Cyan
Write-Host ('=' * 74) -ForegroundColor Cyan
$script:Results | Format-Table -AutoSize -Property Check, Status, Detail | Out-String -Width 200 |
    ForEach-Object { Write-Host $_ }

$failed = @($script:Results | Where-Object { $_.Status -in @('FAIL', 'FAILED') })
$changed = @($script:Results | Where-Object { $_.Status -eq 'FIXED' })

Write-Log ("changed: {0}   unchanged: {1}   failed: {2}" -f $changed.Count, ($script:Results.Count - $changed.Count - $failed.Count), $failed.Count) INFO
Write-Host ''
Write-Log "ERPNext       : $ErpUrl" INFO
Write-Log "Node-RED      : $NodeRedUrl" INFO
Write-Log "Public tunnel : $($script:PublicUrl)" INFO
Write-Log "Log file      : $LogFile" INFO

if ($script:DryRun) { Write-Log 'dry run (-WhatIf): nothing was written' DRY }

if ($failed.Count -gt 0) {
    Write-Log 'finished with failures - see the rows marked FAIL above' FAIL
    exit 1
}
Write-Log 'setup complete' OK
exit 0
