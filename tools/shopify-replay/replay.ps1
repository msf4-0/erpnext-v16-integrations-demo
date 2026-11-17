param(
    [string]$Payload = 'payloads/order-1001.json',
    [string]$Site = 'frontend',
    [string]$Container = 'comp_demo-bench-1'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $root
try {
    $payloadPath = (Resolve-Path $Payload).Path
    & docker inspect $Container *> $null
    if ($LASTEXITCODE -ne 0) { throw "container $Container is not running - start the stack first" }
    & docker cp $payloadPath "${Container}:/tmp/shopify-order.json"
    & docker cp (Join-Path $root 'replay.py') "${Container}:/tmp/shopify-replay.py"
    & docker cp (Join-Path $root 'replay-in-container.sh') "${Container}:/tmp/shopify-replay.sh"
    & docker exec $Container bash /tmp/shopify-replay.sh $Site
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
