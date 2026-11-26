param(
  [string]$BaseUrl = "http://localhost:3005",
  [string]$AdminEmail = "admin@demo.local",
  [string]$AdminPassword = "DemoPass2026!"
)
$ErrorActionPreference = "Stop"
$sess = Invoke-RestMethod -Uri "$BaseUrl/api/session" -Method Post -ContentType "application/json" `
  -Body (@{ username = $AdminEmail; password = $AdminPassword } | ConvertTo-Json)
$hdr = @{ "X-Metabase-Session" = $sess.id }
$dash = (Invoke-RestMethod -Uri "$BaseUrl/api/dashboard/2" -Headers $hdr)
foreach ($dc in $dash.dashcards) {
  $r = Invoke-RestMethod -Uri "$BaseUrl/api/card/$($dc.card_id)/query" -Method Post -Headers $hdr `
        -ContentType "application/json" -Body "{}"
  $rows = $r.data.rows
  Write-Host ("card {0,-2} '{1}' -> status={2} cols={3} rows={4}" -f $dc.card_id, $dc.card.name, $r.status, ($r.data.cols | Measure-Object).Count, ($rows | Measure-Object).Count)
  if ($rows) { Write-Host ("     first row: " + (($rows[0] | ForEach-Object { "$_" }) -join ' | ')) }
}
