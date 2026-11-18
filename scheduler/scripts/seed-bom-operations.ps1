<#
.SYNOPSIS
    Ensure the demo BOMs actually carry operations, so ERPNext creates Job Cards.

.DESCRIPTION
    ERPNext only generates Job Cards for a submitted Work Order when that Work
    Order has an `operations` table. Work Orders built from a BOM with
    `with_operations = 0` submit fine but produce ZERO Job Cards, which makes the
    production planner look broken: nothing to drag, nothing to start.

    The seeded demo BOMs (BOM-FG-BENCH-01-001, BOM-FG-CABINET-01-001, ...) are
    all `with_operations = 0`. This script creates a routable replacement BOM per
    finished good (`...-002`), copies the original items across, attaches the
    demo routing (Cutting -> Assembly -> Packing) and submits it.

    Idempotent: a BOM that already exists with operations is left untouched.

.PARAMETER ErpNextUrl
    Base URL of the bench (host side), default http://localhost:8000

.PARAMETER ApiKey / ApiSecret
    ERPNext API credentials. Defaults come from the scheduler container env or
    the root .env (SCHEDULER_ERPNEXT_API_KEY / SECRET).

.EXAMPLE
    .\seed-bom-operations.ps1
    .\seed-bom-operations.ps1 -ErpNextUrl http://localhost:8000 -ApiKey xxx -ApiSecret yyy
#>
[CmdletBinding()]
param(
    [string]$ErpNextUrl = 'http://localhost:8000',
    [string]$ApiKey,
    [string]$ApiSecret
)

$ErrorActionPreference = 'Stop'

function Get-EnvValue([string]$name) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ($v) { return $v }
    $envFile = Join-Path $PSScriptRoot '..\..\.env'
    if (Test-Path $envFile) {
        $line = Get-Content $envFile | Where-Object { $_ -match "^\s*$name\s*=" } | Select-Object -First 1
        if ($line) { return ($line -split '=', 2)[1].Trim() }
    }
    return $null
}

if (-not $ApiKey)    { $ApiKey    = Get-EnvValue 'SCHEDULER_ERPNEXT_API_KEY' }
if (-not $ApiSecret) { $ApiSecret = Get-EnvValue 'SCHEDULER_ERPNEXT_API_SECRET' }
if (-not $ApiKey -or -not $ApiSecret) {
    throw "Missing ERPNext API key/secret. Pass -ApiKey/-ApiSecret or set SCHEDULER_ERPNEXT_API_KEY/SECRET in the root .env"
}

$script:Headers = @{
    Authorization = "token ${ApiKey}:${ApiSecret}"
    'Content-Type' = 'application/json'
}

function Invoke-Erp([string]$method, [string]$path, $body) {
    $uri = "$ErpNextUrl$path"
    $params = @{ Uri = $uri; Headers = $script:Headers; Method = $method; TimeoutSec = 60 }
    if ($null -ne $body) { $params.Body = ($body | ConvertTo-Json -Depth 8) }
    (Invoke-RestMethod @params).data
}

# Demo routing. Keep in sync with the seeded Operation / Workstation records.
$Routing = @(
    @{ operation = 'Cutting';  workstation = 'WS-CUTTING';  time_in_mins = 30; sequence_id = 1; hour_rate = 50; batch_size = 1; description = 'Cut stock to size' },
    @{ operation = 'Assembly'; workstation = 'WS-ASSEMBLY'; time_in_mins = 90; sequence_id = 2; hour_rate = 60; batch_size = 1; description = 'Assemble frame' },
    @{ operation = 'Packing';  workstation = 'WS-PACKING';  time_in_mins = 15; sequence_id = 3; hour_rate = 40; batch_size = 1; description = 'Pack for dispatch' }
)

$targets = @(
    'BOM-FG-BENCH-01-001',
    'BOM-FG-CABINET-01-001'
)

$results = @()

foreach ($bomName in $targets) {
    Write-Host "`n=== $bomName ===" -ForegroundColor Cyan

    try {
        $src = Invoke-Erp 'GET' "/api/resource/BOM/$bomName"
    } catch {
        Write-Warning "  source BOM $bomName not found - skipping"
        continue
    }

    if (@($src.operations).Count -gt 0) {
        Write-Host "  already has $(@($src.operations).Count) operation(s) - skipping" -ForegroundColor Green
        $results += [pscustomobject]@{ Bom = $bomName; Action = 'skipped (already routable)'; NewBom = $src.name }
        continue
    }

    # Reuse an existing routable replacement if a previous run already made one.
    $existing = Invoke-Erp 'GET' "/api/resource/BOM?filters=%5B%5B%22item%22%2C%22%3D%22%2C%22$($src.item)%22%5D%2C%5B%22with_operations%22%2C%22%3D%22%2C1%5D%2C%5B%22docstatus%22%2C%22%3D%22%2C1%5D%5D&fields=%5B%22name%22%5D"
    if (@($existing).Count -gt 0) {
        Write-Host "  routable BOM already exists: $($existing[0].name) - skipping" -ForegroundColor Green
        $results += [pscustomobject]@{ Bom = $bomName; Action = 'skipped (replacement exists)'; NewBom = $existing[0].name }
        continue
    }

    $items = @($src.items | ForEach-Object {
        @{
            item_code        = $_.item_code
            qty              = $_.qty
            rate             = $_.rate
            uom              = $_.uom
            stock_uom        = $_.stock_uom
            source_warehouse = $_.source_warehouse
        }
    })

    $payload = @{
        item              = $src.item
        company           = $src.company
        quantity          = 1
        uom               = $src.uom
        currency          = $src.currency
        conversion_rate   = 1
        rm_cost_as_per    = 'Valuation Rate'
        with_operations   = 1
        is_active         = 1
        is_default        = 0
        items             = $items
        operations        = $Routing
    }

    try {
        $created = Invoke-Erp 'POST' '/api/resource/BOM' $payload
        Write-Host "  created $($created.name) with $(@($created.operations).Count) operation(s)" -ForegroundColor Green

        $submitted = Invoke-Erp 'PUT' "/api/resource/BOM/$($created.name)" @{ docstatus = 1 }
        Write-Host "  submitted (docstatus $($submitted.docstatus))" -ForegroundColor Green

        $results += [pscustomobject]@{ Bom = $bomName; Action = 'created + submitted'; NewBom = $created.name }
    } catch {
        Write-Warning "  FAILED: $($_.Exception.Message)"
        $results += [pscustomobject]@{ Bom = $bomName; Action = "failed: $($_.Exception.Message)"; NewBom = '' }
    }
}

Write-Host "`n=== summary ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize

Write-Host @"

Next: create Work Orders from the NEW BOM names above (the planner's
"Create Work Order" dialog lists BOMs; pick the ...-002 one). A Work Order built
from a routable BOM submits and ERPNext generates one Job Card per operation.
"@ -ForegroundColor Yellow
