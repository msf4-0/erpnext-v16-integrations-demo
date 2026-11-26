<#
.SYNOPSIS
    Stable front door for the ERPNext comp_demo operator commands.

.DESCRIPTION
    The real implementation lives in setup\setup.ps1.  This file is a forwarder:
    it exists so that the command you type never changes, even if the scripts are
    reorganised again.  When the `setup\` folder moves, only this file needs
    updating - not your notes, your aliases, or your muscle memory.

    Every documented form works unchanged:

        .\setup.ps1                 converge + verify the stack
        .\setup.ps1 -VerifyOnly     read-only health report (~30 s)
        .\setup.ps1 -Full           rebuild from zero, then converge
        .\setup.ps1 -Full -Wipe     same, after deleting volumes (DESTROYS DATA)

    The exit code is passed straight through, so `$LASTEXITCODE` (or
    `%ERRORLEVEL%`) still means exactly what it did before: 0 = healthy,
    1 = setup incomplete, 2 = couldn't run.

.NOTES
    Arguments are forwarded through a child PowerShell using `-File`, not by
    splatting `$args`.  That distinction matters: when a script has no `param()`
    block, `-VerifyOnly` arrives in `$args` as the plain string '-VerifyOnly',
    and splatting it would hand it to the target as a positional *value* instead
    of a switch.  Going through `-File` keeps the original command-line tokens,
    so switches stay switches.

.EXAMPLE
    .\setup.ps1 -VerifyOnly

.EXAMPLE
    .\setup.ps1
#>

$target = Join-Path $PSScriptRoot 'setup\setup.ps1'

if (-not (Test-Path -LiteralPath $target)) {
    Write-Host "  FAIL  ${target} is missing - the setup\ folder has moved." -ForegroundColor Red
    Write-Host "        Point this forwarder ($PSCommandPath) at the new location." -ForegroundColor Red
    exit 2
}

$hostExe = (Get-Process -Id $PID).Path
& $hostExe -NoProfile -ExecutionPolicy Bypass -File $target @args
exit $LASTEXITCODE
