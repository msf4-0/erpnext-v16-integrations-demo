# Sanitize the vendored Node-RED export so it can be committed.
#
# sandbox/node-red/source-flow.json is the operator's downloaded export and it
# carries live credentials in its node headers:
#   * 6 Shopify Admin API tokens   (shpat_...)
#   * 11 ERPNext API tokens        (key:secret)
# build-flows.py rewrites every one of these from .env when it produces
# flows.json, so replacing them with obviously-fake constants is safe and keeps
# the export usable for rebuilds while removing the leak from git history.
param(
    [string]$Path = 'F:\ERPNEXT\erpnextcomp_demo\sandbox\node-red\source-flow.json'
)

$raw = Get-Content -LiteralPath $Path -Raw
$before = @($raw | ConvertFrom-Json)

$shopFake = 'REDACTED'
$erpFake = 'aaaaaaaaaaaaaaa:bbbbbbbbbbbbbbb'

$raw2 = [regex]::Replace($raw, 'shpat_[0-9A-Za-z]{20,}', $shopFake)
$raw2 = [regex]::Replace($raw2, '[0-9a-f]{12,}:[0-9a-f]{12,}', $erpFake)
$raw2 = [regex]::Replace($raw2, 'shpss_[0-9A-Za-z]{20,}', 'shpss_' + ('0' * 32))

if ($raw2 -eq $raw) {
    Write-Output 'nothing to sanitize (already clean)'
    exit 0
}

# backup OUTSIDE git so the original is not committed by accident
$cache = Join-Path (Split-Path (Split-Path $Path -Parent) -Parent) '.cache'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$bak = Join-Path $cache ('source-flow.original.' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.json')
Copy-Item -LiteralPath $Path -Destination $bak -Force
Write-Output "backup (outside git): $bak"

$after = @($raw2 | ConvertFrom-Json)
if ($after.Count -ne $before.Count) {
    Write-Error "node count changed ($($before.Count) -> $($after.Count)) - aborting"
    exit 1
}

[System.IO.File]::WriteAllText($Path, $raw2, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "sanitized: $(($before.Count)) nodes, JSON still valid"

$leftoverShop = ([regex]::Matches($raw2, 'shpat_(?!0{32})[0-9A-Za-z]{20,}')).Count
$leftoverErp = ([regex]::Matches($raw2, '[0-9a-f]{12,}:[0-9a-f]{12,}')).Count
Write-Output "remaining live shopify tokens: $leftoverShop"
Write-Output "remaining live ERPNext tokens:  $leftoverErp"
