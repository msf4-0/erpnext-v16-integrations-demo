# Build the 4 ERPNext monitoring questions + one dashboard in Metabase (idempotent).
param(
  [string]$BaseUrl = "http://localhost:3005",
  [string]$AdminEmail = "admin@demo.local",
  [string]$AdminPassword = "DemoPass2026!"
)
$ErrorActionPreference = "Stop"

$sess = Invoke-RestMethod -Uri "$BaseUrl/api/session" -Method Post -ContentType "application/json" `
  -Body (@{ username = $AdminEmail; password = $AdminPassword } | ConvertTo-Json)
$hdr = @{ "X-Metabase-Session" = $sess.id }

# Resolve the ERPNext data source by name instead of hard-coding id=2: the id
# depends on the order databases were added, and the site DB name changes
# whenever the site is recreated.
$dbs = Invoke-RestMethod -Uri "$BaseUrl/api/database" -Headers $hdr
$dbEntry = $dbs.data | Where-Object { $_.name -eq "ERPNext" } | Select-Object -First 1
if (-not $dbEntry) { throw "No data source named 'ERPNext' in Metabase - run metabase-seed.ps1 first." }
$dbId = $dbEntry.id
Write-Host ("using data source 'ERPNext' id={0}" -f $dbId)

$sql1 = @'
SELECT status AS Status, COUNT(*) AS Orders FROM `tabSales Order` GROUP BY status ORDER BY Orders DESC
'@
$sql2 = @'
SELECT status AS Status, COUNT(*) AS Orders, COALESCE(SUM(grand_total),0) AS Value FROM `tabPurchase Order` GROUP BY status ORDER BY Orders DESC
'@
$sql3 = @'
SELECT COALESCE(w.workstation_name, '(none)') AS Workstation, COUNT(j.name) AS JobCards, COUNT(DISTINCT j.work_order) AS WorkOrders, COALESCE(SUM(j.for_quantity),0) AS PlannedQty, COALESCE(SUM(j.total_completed_qty),0) AS CompletedQty FROM `tabJob Card` j LEFT JOIN `tabWorkstation` w ON w.name = j.workstation GROUP BY w.workstation_name ORDER BY JobCards DESC
'@
$sql4 = @'
SELECT so.status AS Status, COALESCE(SUM(soi.qty),0) AS OrderedQty, COALESCE(SUM(dni.qty),0) AS DeliveredQty, (COALESCE(SUM(soi.qty),0) - COALESCE(SUM(dni.qty),0)) AS PendingQty FROM `tabSales Order` so LEFT JOIN `tabSales Order Item` soi ON soi.parent = so.name LEFT JOIN `tabDelivery Note Item` dni ON dni.against_sales_order = so.name GROUP BY so.status ORDER BY OrderedQty DESC
'@

$cards = @(
  @{ name = "Sales Order by Status (pie)"; display = "pie"; sql = $sql1 },
  @{ name = "Purchase Order by Status"; display = "bar"; sql = $sql2 },
  @{ name = "Workstation Monitoring (Job Card + Work Order)"; display = "table"; sql = $sql3 },
  @{ name = "Sales Order Delivery Status"; display = "table"; sql = $sql4 }
)

# create collection (ignore if exists error by trying to find first)
$coll = $null
try { $coll = Invoke-RestMethod -Uri "$BaseUrl/api/collection" -Method Post -Headers $hdr -ContentType "application/json" -Body (@{ name = "ERPNext Monitoring"; color = "#509EE3" } | ConvertTo-Json) }
catch { $coll = Invoke-RestMethod -Uri "$BaseUrl/api/collection/root" -Headers $hdr }

$cardIds = @()
foreach ($c in $cards) {
  $body = @{
    name = $c.name
    display = $c.display
    dataset_query = @{ database = $dbId; type = "native"; native = @{ query = $c.sql; "template-tags" = @{} } }
    visualization_settings = @{}
    parameters = @()
  } | ConvertTo-Json -Depth 8
  $card = Invoke-RestMethod -Uri "$BaseUrl/api/card" -Method Post -Headers $hdr -ContentType "application/json" -Body $body
  $cardIds += $card.id
  Write-Host ("created card id={0} : {1}" -f $card.id, $c.name)
}

$dash = Invoke-RestMethod -Uri "$BaseUrl/api/dashboard" -Method Post -Headers $hdr `
  -ContentType "application/json" -Body (@{ name = "ERPNext Monitoring" } | ConvertTo-Json)

foreach ($cid in $cardIds) {
  Invoke-RestMethod -Uri "$BaseUrl/api/dashboard/$($dash.id)/cards" -Method Post -Headers $hdr `
    -ContentType "application/json" -Body (@{ cardId = $cid } | ConvertTo-Json) | Out-Null
}

Write-Host ("dashboard id={0} name={1} cards={2}" -f $dash.id, $dash.name, $cardIds.Count)
@{ collection_id = $coll.id; card_ids = $cardIds; dashboard_id = $dash.id } | ConvertTo-Json | Set-Content "$env:TEMP\mb_built.json"
Write-Host "saved -> $env:TEMP\mb_built.json"
