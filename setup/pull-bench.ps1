<#
.SYNOPSIS
    Make the prebuilt comp_demo bench image available locally, cheaply.

.DESCRIPTION
    `docker compose create` silently builds the 3 GB bench image when its tag is
    not present, which is the 25-40 minute "setup never finishes" stall.

    Try three paths, in order:
      1. GHCR pull of ghcr.io/msf4-0/comp-demo-bench:v16 (fast when public)
      2. GitHub Release bundle: one ~1 GB tarball + sha256, then `docker load`.
         This works while the GHCR package is private - no account, no PAT.
      3. Give up and let the caller build locally.

    Exit codes:
      0  image is present (already local, pulled, or loaded from the bundle)
      2  no path worked - caller should fall back to the local build
      1  hard error (no docker / no compose file)

    Used by up.ps1, setup.ps1 -Full and start.ps1.

.PARAMETER Force
    Skip the "already present" shortcut and re-fetch.
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$EnvPath = Join-Path $Root '.env'
$LocalTag = 'comp_demo-bench:v16'
$GhcrImage = 'ghcr.io/msf4-0/comp-demo-bench:v16'
# No default: the bench image is NOT published publicly (company policy blocks a
# public GHCR package / public release asset), so guessing a URL only produces a
# long failure before the inevitable local build. Set BENCH_BUNDLE_URL when you
# host the tarball somewhere your users can reach (internal registry, SMB share).
$BundleUrl = if ($env:BENCH_BUNDLE_URL) { $env:BENCH_BUNDLE_URL } else { '' }

function Say([string]$m)  { Write-Host "  ...   $m" }
function Ok([string]$m)   { Write-Host "  OK    $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "  WARN  $m" -ForegroundColor Yellow }

if (Test-Path $EnvPath) {
    foreach ($line in Get-Content $EnvPath) {
        if ($line -match '^\s*BENCH_IMAGE\s*=\s*(.+?)\s*$') {
            # Only a namespaced ref is a pull target; a bare tag is the local name.
            if ($Matches[1] -match '/') { $GhcrImage = $Matches[1] }
        }
        if ($line -match '^\s*BENCH_BUNDLE_URL\s*=\s*(.+?)\s*$') {
            if ($Matches[1] -match '^https?://') { $BundleUrl = $Matches[1] }
        }
    }
}

& docker image inspect $LocalTag *> $null
if ($LASTEXITCODE -eq 0 -and -not $Force) {
    Ok "bench image already present ($LocalTag)"
    exit 0
}

# ---------------------------------------------------------------------------
# 0. can we pull at all?
# ---------------------------------------------------------------------------
# A local build is the DEFAULT path for a new user. Pulling is an opt-in
# shortcut: BENCH_PULL_GHCR=1 for an internal/authorised registry, or BENCH_IMAGE
# set to a namespaced ref your Docker can already reach.
$allowGhcr = ($env:BENCH_PULL_GHCR -eq '1') -or ($GhcrImage -notmatch '^ghcr\.io/msf4-0/')
if (-not $allowGhcr -and -not $BundleUrl) {
    Warn 'no pullable image configured - this is expected for a fresh clone'
    Warn 'building comp_demo-bench locally (25-40 minutes, once)'
    exit 2
}

# ---------------------------------------------------------------------------
# 1. GHCR
# ---------------------------------------------------------------------------
Say "pulling $GhcrImage (3 GB uncompressed, ~1 GB on the wire)"
$sw = [Diagnostics.Stopwatch]::StartNew()
# cmd /c keeps docker's stderr as plain text: PS 5.1 turns native stderr into a
# terminating NativeCommandError under $ErrorActionPreference='Stop', which
# would exit 1 here instead of the documented 2.
$out = cmd /c "docker pull --platform linux/amd64 $GhcrImage 2>&1"
$rc = $LASTEXITCODE
$out | Select-Object -Last 2 | ForEach-Object { Write-Host "        $_" }
if ($rc -eq 0) {
    & docker tag $GhcrImage $LocalTag | Out-Null
    Ok ("bench image pulled in {0:n1} min" -f $sw.Elapsed.TotalMinutes)
    exit 0
}

Warn 'GHCR pull failed (package private, or no access) - trying the GitHub Release bundle'
Warn '  permanent fix (org owner): https://github.com/organizations/msf4-0/settings/packages'
Warn '                             -> allow public packages, then package settings -> Public'

# ---------------------------------------------------------------------------
# 2. Release bundle
# ---------------------------------------------------------------------------
$bundle = Join-Path $env:TEMP 'comp-demo-bench-v16-amd64.tar.gz'
$shaFile = "$bundle.sha256"
try {
    Say "downloading $BundleUrl (~1 GB, one time)"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest $BundleUrl -OutFile $bundle -UseBasicParsing -TimeoutSec 1800
    $expected = $null
    try {
        # PS 5.1 hands back byte[] for text/plain here, so decode before matching.
        $shaResp = Invoke-WebRequest "$BundleUrl.sha256" -UseBasicParsing -TimeoutSec 60
        $shaText = if ($shaResp.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($shaResp.Content)
        } else { [string]$shaResp.Content }
        if ($shaText -match '([0-9a-fA-F]{64})') { $expected = $Matches[1].ToLower() }
    } catch { Warn 'no .sha256 published - skipping checksum verification' }
    if ($expected) {
        $actual = (Get-FileHash $bundle -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $expected) { throw "checksum mismatch: expected $expected, got $actual" }
        Ok 'bundle checksum verified'
    } elseif ($shaText) {
        Warn 'downloaded .sha256 but could not parse it - continuing unverified'
    }
    Say 'docker load'
    $loadOut = cmd /c "docker load -i `"$bundle`" 2>&1"
    $loadRc = $LASTEXITCODE
    $loadOut | Select-Object -Last 3 | ForEach-Object { Write-Host "        $_" }
    if ($loadRc -ne 0) { throw "docker load failed (exit $loadRc)" }
    & docker image inspect $LocalTag *> $null
    if ($LASTEXITCODE -ne 0) {
        # The bundle may carry a different tag; retag whatever it loaded.
        $loaded = (cmd /c "docker images --format `"{{.Repository}}:{{.Tag}}`" comp_demo-bench 2>&1" | Select-Object -First 1)
        if ($loaded) { & docker tag $loaded $LocalTag | Out-Null }
    }
    & docker image inspect $LocalTag *> $null
    if ($LASTEXITCODE -ne 0) { throw 'loaded the bundle but comp_demo-bench:v16 is still missing' }
    Ok ("bench image loaded from the release bundle in {0:n1} min" -f $sw.Elapsed.TotalMinutes)
    try { Remove-Item $bundle, $shaFile -Force -ErrorAction SilentlyContinue } catch { }
    exit 0
} catch {
    Warn "release bundle unavailable: $($_.Exception.Message)"
    Warn 'falling back to a local build - 25-40 minutes, once'
    exit 2
}
