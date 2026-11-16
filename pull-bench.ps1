<#
.SYNOPSIS
    Make the prebuilt comp_demo bench image available locally, cheaply.

.DESCRIPTION
    `docker compose create` silently builds the 3 GB bench image when its tag is
    not present, which is the 25-40 minute "setup never finishes" stall. This
    script tries the GHCR image first and tags it as the local
    `comp_demo-bench:v16`, so compose starts without a build.

    Exit codes:
      0  image is present (already local, or pulled now)
      2  pull failed (private package / offline) - caller should fall back to
         the local build; the exact remediation link is printed
      1  hard error (no docker / no compose file)

    Used by up.ps1 (and therefore setup.ps1 -Full). start.ps1 has its own
    equivalent inline step so the newcomer path stays a single file.

.PARAMETER Force
    Pull even when the local tag already exists.
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvPath = Join-Path $Root '.env'
$LocalTag = 'comp_demo-bench:v16'
$GhcrImage = 'ghcr.io/msf4-0/comp-demo-bench:v16'

function Say([string]$m)  { Write-Host "  ...   $m" }
function Ok([string]$m)   { Write-Host "  OK    $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "  WARN  $m" -ForegroundColor Yellow }

if (Test-Path $EnvPath) {
    foreach ($line in Get-Content $EnvPath) {
        if ($line -match '^\s*BENCH_IMAGE\s*=\s*(.+?)\s*$') {
            # Only a namespaced ref is a pull target; a bare tag is the local name.
            if ($Matches[1] -match '/') { $GhcrImage = $Matches[1] }
        }
    }
}

& docker image inspect $LocalTag *> $null
if ($LASTEXITCODE -eq 0 -and -not $Force) {
    Ok "bench image already present ($LocalTag)"
    exit 0
}

Say "pulling $GhcrImage (3 GB, one time)"
$sw = [Diagnostics.Stopwatch]::StartNew()
# cmd /c keeps docker's stderr as plain text: PS 5.1 turns native stderr into a
# terminating NativeCommandError under $ErrorActionPreference='Stop', which
# would exit 1 here instead of the documented 2.
$out = cmd /c "docker pull --platform linux/amd64 $GhcrImage 2>&1"
$rc = $LASTEXITCODE
$out | Select-Object -Last 2 | ForEach-Object { Write-Host "        $_" }
if ($rc -ne 0) {
    Warn 'prebuilt bench image not pullable (package still private, or offline)'
    Warn '  one-time fix: https://github.com/msf4-0?tab=packages -> comp-demo-bench'
    Warn '                -> Package settings -> Change visibility -> Public'
    Warn '  falling back to a local build - 25-40 minutes, once'
    exit 2
}
& docker tag $GhcrImage $LocalTag | Out-Null
Ok ("bench image pulled in {0:n1} min" -f $sw.Elapsed.TotalMinutes)
exit 0
