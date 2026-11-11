param(
  [string]$BaseUrl = "http://localhost:3005",
  [string]$AdminEmail = "admin@demo.local",
  [string]$AdminPassword = "DemoPass2026!"
)
$ErrorActionPreference = "Stop"
$sess = Invoke-RestMethod -Uri "$BaseUrl/api/session" -Method Post -ContentType "application/json" `
  -Body (@{ username = $AdminEmail; password = $AdminPassword } | ConvertTo-Json)
$hdr = @{ "X-Metabase-Session" = $sess.id }

$all = Invoke-RestMethod -Uri "$BaseUrl/api/dashboard" -Headers $hdr
$dash = $all | Where-Object { $_.name -eq "ERPNext Monitoring" } | Select-Object -First 1
if (-not $dash) {
  $dash = Invoke-RestMethod -Uri "$BaseUrl/api/dashboard" -Method Post -Headers $hdr `
    -ContentType "application/json" -Body (@{ name = "ERPNext Monitoring" } | ConvertTo-Json)
  Write-Host ("created dashboard id={0}" -f $dash.id)
} else {
  Write-Host ("reusing dashboard id={0}" -f $dash.id)
}

$cards = (Invoke-RestMethod -Uri "$BaseUrl/api/card" -Headers $hdr) |
  Where-Object { $_.name -in @("Sales Order by Status (pie)", "Purchase Order by Status",
                               "Workstation Monitoring (Job Card + Work Order)", "Sales Order Delivery Status") }
Write-Host ("found {0} cards" -f ($cards | Measure-Object).Count)

$dashcards = @()
$i = 0
foreach ($c in $cards) {
  $dashcards += [ordered]@{
    id = (-1 - $i); card_id = $c.id; row = [math]::Floor($i / 2) * 6; col = ($i % 2) * 9;
    size_x = 9; size_y = 6; visualization_settings = @{}; parameter_mappings = @(); series = @()
  }
  $i++
}
$body = @{ dashcards = $dashcards } | ConvertTo-Json -Depth 10
Invoke-RestMethod -Uri "$BaseUrl/api/dashboard/$($dash.id)" -Method Put -Headers $hdr -ContentType "application/json" -Body $body | Out-Null

$check = Invoke-RestMethod -Uri "$BaseUrl/api/dashboard/$($dash.id)" -Headers $hdr
Write-Host ("dashboard {0} '{1}' dashcards={2}" -f $check.id, $check.name, ($check.dashcards | Measure-Object).Count)
foreach ($dc in $check.dashcards) { Write-Host ("  card {0} {1} {2}x{3} @ {4},{5}" -f $dc.card_id, $dc.card.name, $dc.size_x, $dc.size_y, $dc.col, $dc.row) }
