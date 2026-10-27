# Trace a Node-RED node: what it is, what feeds it, what it feeds.
param([string]$FlowPath, [string]$NodeId)

$raw = Get-Content -LiteralPath $FlowPath -Raw
$parsed = $raw | ConvertFrom-Json
if ($parsed -is [array]) { $flow = @($parsed) } else { $flow = @($parsed[0]) }
if ($flow.Count -eq 1 -and $flow[0] -is [array]) { $flow = @($flow[0]) }

Write-Output "TOTAL NODES: $($flow.Count)"

function NameOf($n) {
    $p = $n.PSObject.Properties['name']
    if ($p -and $p.Value) { return [string]$p.Value }
    return "(unnamed)"
}
function IdOf($n) { return [string]$n.id }

$byId = @{}
foreach ($n in $flow) { $byId[(IdOf $n)] = $n }

$target = $byId[$NodeId]
Write-Output ""
Write-Output "=== TARGET $NodeId ==="
if (-not $target) {
    Write-Output "NOT FOUND"
    exit
}
Write-Output "type : $($target.type)"
Write-Output "name : $(NameOf $target)"
Write-Output "tab  : $($target.z)"
if ($target.PSObject.Properties['func']) {
    Write-Output "--- func code ---"
    Write-Output $target.func
    Write-Output "--- end func ---"
}

Write-Output ""
Write-Output "=== UPSTREAM (nodes that wire into it) ==="
foreach ($n in $flow) {
    if (-not $n.PSObject.Properties['wires']) { continue }
    $hit = $false
    foreach ($out in $n.wires) {
        foreach ($t in @($out)) { if ($t -eq $NodeId) { $hit = $true } }
    }
    if ($hit) {
        Write-Output ("  {0,-14} {1,-28} id={2}" -f $n.type, (NameOf $n), $n.id)
        if ($n.PSObject.Properties['url']) { Write-Output ("       url: " + $n.url) }
        if ($n.PSObject.Properties['method']) { Write-Output ("       method: " + $n.method) }
    }
}

Write-Output ""
Write-Output "=== DOWNSTREAM ==="
foreach ($out in $target.wires) {
    foreach ($t in @($out)) {
        $d = $byId[$t]
        if ($d) { Write-Output ("  {0,-14} {1,-28} id={2}" -f $d.type, (NameOf $d), $d.id) }
    }
}

Write-Output ""
Write-Output "=== TAB NODES (same tab as target) ==="
foreach ($n in $flow) {
    if ($n.z -ne $target.z) { continue }
    $outs = @()
    if ($n.PSObject.Properties['wires']) {
        foreach ($out in $n.wires) { foreach ($t in @($out)) { $d = $byId[$t]; if ($d) { $outs += (NameOf $d) } } }
    }
    Write-Output ("  {0,-14} {1,-28} -> {2}" -f $n.type, (NameOf $n), ($outs -join ', '))
}
