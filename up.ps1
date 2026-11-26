<#
.SYNOPSIS
    Stable front door for the full bring-up (up.ps1).

.DESCRIPTION
    The real implementation lives in setup\up.ps1.  This forwarder keeps the
    command name `.\up.ps1` working however the `setup\` folder is arranged.

    `up.ps1` is the full, slow path: pull or build the bench image, create and
    start the containers in a safe order, wait for the seed restore, install the
    apps, then hand over to `setup.ps1` to converge.  Expect 25-40 minutes on a
    first run; use `.\setup.ps1` for the routine, idempotent pass.

    Arguments are forwarded through a child PowerShell using `-File` (see the
    note in setup.ps1 for why splatting `$args` would break switches).

.EXAMPLE
    .\up.ps1 -Help
#>

$target = Join-Path $PSScriptRoot 'setup\up.ps1'

if (-not (Test-Path -LiteralPath $target)) {
    Write-Host "  FAIL  ${target} is missing - the setup\ folder has moved." -ForegroundColor Red
    Write-Host "        Point this forwarder ($PSCommandPath) at the new location." -ForegroundColor Red
    exit 2
}

$hostExe = (Get-Process -Id $PID).Path
& $hostExe -NoProfile -ExecutionPolicy Bypass -File $target @args
exit $LASTEXITCODE
