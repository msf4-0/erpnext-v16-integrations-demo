<#
.SYNOPSIS
    Proves the non-admin demo login can actually transact.

.DESCRIPTION
    The 2026-11 regression: `demo@compdemo.local` could log in and read every
    record, but saving a Delivery Note or Sales Invoice failed with
    "User don't have permissions to select/read this account" because the
    `Demo User` role had no read/select on ERPNext's finance masters. Nothing in
    verify-clean-clone.ps1 caught it, because that gate only checks HTTP 200s.

    This script exercises the real flow: log in as the demo user, create the
    three documents every advertised feature depends on (Delivery Note for the
    barcode scan, Sales Invoice for e-invoicing, Stock Entry for item tracking),
    then delete them as Administrator. Created documents are drafts, so no stock
    or ledger is touched.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tests\verify-demo-user.ps1
#>
param(
    [string]$BaseUrl,
    [string]$Email = 'demo@compdemo.local',
    [string]$Password = 'demo'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $BaseUrl) {
    $envFile = Join-Path $Root '.env'
    $port = '8000'
    if (Test-Path $envFile) {
        $m = Select-String -Path $envFile -Pattern '^ERPNEXT_PORT=(.*)$' | Select-Object -First 1
        if ($m) { $port = $m.Matches.Groups[1].Value.Trim() }
    }
    $BaseUrl = "http://localhost:$port"
}

$script:Failures = @()
function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "  OK    $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:Failures += $what }
}

$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
try {
    $login = Invoke-RestMethod -Uri "$BaseUrl/api/method/login" -Method Post `
        -Body @{ usr = $Email; pwd = $Password } -WebSession $session -TimeoutSec 30
    Check ($login.message -eq 'Logged In') "login as $Email"
} catch {
    Write-Host "  FAIL  login as $Email : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

function Get-First([string]$Doctype, [string]$Fields = '%5B%22name%22%5D') {
    $u = "$BaseUrl/api/resource/$([uri]::EscapeDataString($Doctype))?fields=$Fields&limit_page_length=1"
    try { return (Invoke-RestMethod -Uri $u -WebSession $session -TimeoutSec 30).data[0] }
    catch { return $null }
}

$item = Get-First 'Item' '%5B%22name%22%2C%22item_code%22%5D'
$customer = Get-First 'Customer'
$warehouse = Get-First 'Warehouse'
Check ([bool]$item -and [bool]$customer -and [bool]$warehouse) 'demo user can read Item / Customer / Warehouse'
if (-not ($item -and $customer -and $warehouse)) { exit 1 }

$headers = @{ 'Content-Type' = 'application/json' }
$created = @()

function Try-Create([string]$Doctype, [hashtable]$Body, [string]$Label) {
    try {
        $r = Invoke-RestMethod -Uri "$BaseUrl/api/resource/$([uri]::EscapeDataString($Doctype))" `
            -Method Post -Body ($Body | ConvertTo-Json -Depth 8) -Headers $headers `
            -WebSession $session -TimeoutSec 60
        $script:created += ,@($Doctype, $r.data.name)
        Check $true "$Label saved ($($r.data.name))"
    } catch {
        $msg = $_.ErrorDetails.Message
        if (-not $msg) { $msg = $_.Exception.Message }
        Check $false "$Label could not be saved: $($msg.Substring(0, [Math]::Min(180, $msg.Length)))"
    }
}

$row = @{ item_code = $item.item_code; qty = 1; warehouse = $warehouse.name }
Try-Create 'Delivery Note' @{
    doctype = 'Delivery Note'; customer = $customer.name; company = 'SHRDC'
    items = @($row)
} 'Delivery Note draft (barcode scan flow)'

Try-Create 'Sales Invoice' @{
    doctype = 'Sales Invoice'; customer = $customer.name; company = 'SHRDC'
    items = @($row)
} 'Sales Invoice draft (e-invoicing flow)'

Try-Create 'Stock Entry' @{
    doctype = 'Stock Entry'; stock_entry_type = 'Material Receipt'; company = 'SHRDC'
    items = @(@{ item_code = $item.item_code; qty = 1; t_warehouse = $warehouse.name })
} 'Stock Entry draft (item tracking flow)'

# Clean up with the Administrator token: the demo role deliberately has no delete.
$token = $null
$envFile = Join-Path $Root '.env'
if (Test-Path $envFile) {
    $m = Select-String -Path $envFile -Pattern '^ERPNEXT_API_TOKEN=(.*)$' | Select-Object -First 1
    if ($m) { $token = $m.Matches.Groups[1].Value.Trim() }
}
if ($token) {
    foreach ($c in $created) {
        try {
            Invoke-RestMethod -Uri "$BaseUrl/api/resource/$([uri]::EscapeDataString($c[0]))/$($c[1])" `
                -Method Delete -Headers @{ Authorization = "token $token" } -TimeoutSec 30 | Out-Null
        } catch {
            Write-Host "  WARN  could not delete $($c[1]) - remove it by hand" -ForegroundColor Yellow
        }
    }
    Write-Host "  ...   cleaned up $($created.Count) draft document(s)"
}

Write-Host ''
if ($script:Failures.Count -eq 0) {
    Write-Host '  DEMO USER OK - the non-admin login can transact' -ForegroundColor Green
    exit 0
}
Write-Host "  DEMO USER BROKEN - $($script:Failures.Count) check(s) failed" -ForegroundColor Red
exit 1
