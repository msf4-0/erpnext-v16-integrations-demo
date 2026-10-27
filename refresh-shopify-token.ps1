<#
.SYNOPSIS
    Mint a fresh Shopify Admin API token and push it everywhere the demo uses it.

.DESCRIPTION
    The custom app on the store issues **24 h** client-credentials tokens, so the
    `shpat_...` value baked into .env and into the Node-RED flow goes stale daily.
    The ERPNext side now mints its own (shopify/auth.py) - this script covers the
    two places that cannot mint for themselves:

      1. `comp_demo/.env`            -> SHOPIFY_ACCESS_TOKEN (used by rebuilds)
      2. the Node-RED flow           -> every Shopify http-request node header
                                        (rebuild via build-flows.py + restart)

    Run it whenever the Node-RED Shopify nodes start answering 401
    (`/delivery-note`, inventory and fulfillment pushes), or just on a schedule:

        schtasks /create /tn "comp_demo shopify token" /sc daily /st 08:00 ^
            /tr "powershell -ExecutionPolicy Bypass -File F:\ERPNEXT\erpnext-build\refresh-shopify-token.ps1"

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File F:\ERPNEXT\erpnext-build\refresh-shopify-token.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipNodeRed,
    [switch]$SkipErpNext
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$DemoDir = $PSScriptRoot
$EnvPath = Join-Path $DemoDir '.env'
$RootDir = $PSScriptRoot
$SandboxDir = Join-Path $RootDir 'sandbox'
$Bench = 'comp_demo-bench-1'

function Read-EnvFile([string]$Path) {
    $table = @{}
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
        if ($lines[$i] -match "^\s*$([regex]::Escape($Key))\s*=") { $lines[$i] = "$Key=$Value"; $found = $true; break }
    }
    if (-not $found) { $lines.Add("$Key=$Value") }
    [System.IO.File]::WriteAllLines($Path, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

$cfg = Read-EnvFile $EnvPath
$store = $cfg['SHOPIFY_STORE']
$version = if ($cfg['SHOPIFY_API_VERSION']) { $cfg['SHOPIFY_API_VERSION'] } else { '2026-04' }
$clientId = $cfg['SHOPIFY_CLIENT_ID']
$clientSecret = $cfg['SHOPIFY_CLIENT_SECRET']

if (-not $store) { throw "SHOPIFY_STORE missing from $EnvPath" }
if (-not $clientId -or -not $clientSecret) {
    throw "SHOPIFY_CLIENT_ID / SHOPIFY_CLIENT_SECRET missing from $EnvPath - cannot mint a token"
}

Write-Host ''
Write-Host ("== minting a Shopify Admin API token for $store ==") -ForegroundColor Cyan
$body = @{ client_id = $clientId; client_secret = $clientSecret; grant_type = 'client_credentials' } | ConvertTo-Json
try {
    $response = Invoke-RestMethod -Uri "https://$store/admin/oauth/access_token" -Method Post `
        -ContentType 'application/json' -Body $body -TimeoutSec 45
} catch {
    throw "token mint failed: $($_.Exception.Message)"
}
$token = $response.access_token
if (-not $token) { throw 'token mint returned no access_token' }

$scopeCount = ($response.scope -split ',')[0..([Math]::Min(3, ($response.scope -split ',').Count - 1))] -join ','
Write-Host ("  token  : {0}...  ({1} chars, expires in {2}s)" -f $token.Substring(0, 12), $token.Length, $response.expires_in) -ForegroundColor Green
Write-Host ("  scope  : {0}... ({1} scopes total)" -f $scopeCount, ($response.scope -split ',').Count)

Set-EnvValue $EnvPath 'SHOPIFY_ACCESS_TOKEN' $token
Write-Host "  .env   : SHOPIFY_ACCESS_TOKEN updated" -ForegroundColor Green

# --- ERPNext side -----------------------------------------------------------
# Its auth.py mints on demand, so this only clears the cached token + the
# "Shopify rejected us" pause gate and re-verifies.
if (-not $SkipErpNext) {
    $py = Join-Path $SandboxDir 'scripts\shopify-token.py'
    if (Test-Path $py) {
        docker cp $py "${Bench}:/tmp/scripts/shopify-token.py" | Out-Null
        docker exec -u root $Bench bash -lc 'chown frappe:frappe /tmp/scripts/shopify-token.py' | Out-Null
        $out = docker exec $Bench bash -lc "cd /home/frappe/frappe-bench && SITE_NAME=frontend ./env/bin/python /tmp/scripts/shopify-token.py verify" 2>&1
        $out | Where-Object { $_ -match '^MARK_' } | ForEach-Object { Write-Host "  erpnext: $_" -ForegroundColor Green }
    } else {
        Write-Host "  erpnext: $py missing - skipped" -ForegroundColor Yellow
    }
}

# --- Node-RED side ----------------------------------------------------------
# The flow has the token baked into each Shopify http-request node, so it needs
# a rebuild + restart. up.ps1 does the same thing during a full build.
if (-not $SkipNodeRed) {
    $flowSrc = $cfg['NODE_RED_SOURCE_FLOW']
    if (-not $flowSrc -or -not (Test-Path $flowSrc)) {
        $fallback = 'F:\shopify_erpnext_integration.json'
        if (Test-Path $fallback) { $flowSrc = $fallback }
    }
    $builder = Join-Path $SandboxDir 'node-red\build-flows.py'
    $flowsPath = Join-Path $SandboxDir 'node-red\flows.json'
    $python = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $python) { $python = (Get-Command python3 -ErrorAction SilentlyContinue).Source }

    if ($flowSrc -and (Test-Path $flowSrc) -and $python) {
        $erpToken = $cfg['ERPNEXT_API_TOKEN']
        & $python $builder --src $flowSrc --out $flowsPath `
            --erpnext-url 'http://bench:8000' --erpnext-token $erpToken `
            --shopify-store $store --shopify-version $version `
            --shopify-token $token --site frontend | Out-Null
        Write-Host ("  node-red: flow rebuilt from {0}" -f (Split-Path $flowSrc -Leaf)) -ForegroundColor Green

        docker restart comp_demo-node-red-1 | Out-Null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 3
            try {
                $code = (Invoke-WebRequest -Uri 'http://localhost:1880/' -UseBasicParsing -TimeoutSec 5).StatusCode
                if ($code -eq 200) { break }
            } catch { }
        }
        Write-Host '  node-red: restarted' -ForegroundColor Green
    } else {
        Write-Host '  node-red: source flow or python missing - skipped' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'Done. Tokens expire 24h after minting; re-run this script (or schedule it).' -ForegroundColor Cyan
Write-Host ''
