# Patch function 12 (5744494e9098b054) in the deployed flow.
#
# What it did before:
#   let orderId = msg.erpnext.shopify_order_id;   <-- throws when msg.erpnext
#                                                     is undefined, and is always
#                                                     undefined for a real Delivery
#                                                     Note (the field lives on
#                                                     Sales Order, not on DN)
#   msg.headers = { "X-Shopify-Access-Token": "shpat_..." }   <-- stale token baked in
#
# What it does now: bail out cleanly when there is no Shopify order id, and leave
# the auth header to the http-request node (which setup-shopify-erpnext.ps1 keeps
# up to date).
param(
    [string]$FlowPath = 'F:\ERPNEXT\erpnextcomp_demo\sandbox\node-red\flows.json',
    [string]$NodeId = '5744494e9098b054',
    [string]$Container = 'comp_demo-node-red-1'
)

$newFunc = @'
const orderId = msg.erpnext && msg.erpnext.shopify_order_id;

if (!orderId) {
    // A Delivery Note has no direct reference to the Shopify order id: the
    // custom field `shopify_order_id` lives on Sales Order. Without it we cannot
    // build a fulfillment_orders URL, so stop this branch instead of calling
    // https://.../orders/undefined/... (which threw a TypeError and spammed the log).
    node.warn("skip Shopify fulfilment: no shopify_order_id on this delivery note");
    return null;
}

msg.url =
    "https://4e1075.myshopify.com/admin/api/2026-04/orders/" +
    orderId +
    "/fulfillment_orders.json";

// Auth header comes from the http request node (kept current by
// setup-shopify-erpnext.ps1) - do not bake a token in here.
delete msg.headers;

return msg;
'@

$backup = "$FlowPath.bak.$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
Copy-Item -LiteralPath $FlowPath -Destination $backup -Force
Write-Output "backup: $(Split-Path $backup -Leaf)"

$raw = Get-Content -LiteralPath $FlowPath -Raw
$parsed = $raw | ConvertFrom-Json
if ($parsed -is [array]) { $flow = @($parsed) } else { $flow = @($parsed[0]) }
if ($flow.Count -eq 1 -and $flow[0] -is [array]) { $flow = @($flow[0]) }

$target = $null
foreach ($n in $flow) { if ([string]$n.id -eq $NodeId) { $target = $n } }
if (-not $target) { Write-Error "node $NodeId not found"; exit 1 }

if ($target.PSObject.Properties['func']) { $target.func = $newFunc }
else { $target | Add-Member -NotePropertyName func -NotePropertyValue $newFunc -Force }
Write-Output "patched func on '$($target.name)'"

$json = ConvertTo-Json -InputObject $flow -Depth 40 -Compress
[System.IO.File]::WriteAllText($FlowPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "wrote $($flow.Count) nodes back to the flow file"

if ($Container) {
    & docker @('restart', $Container) | Out-Null
    Write-Output "restarted $Container"
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 3
        try {
            $live = Invoke-RestMethod 'http://localhost:1880/flows' -TimeoutSec 6
            if ($live) { Write-Output "runtime reports $(@($live).Count) nodes"; break }
        } catch { }
    }
}
