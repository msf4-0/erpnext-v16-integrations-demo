<#
.SYNOPSIS
    Produce the centralised, portable comp_demo bundle (clean copy + zip + checksum).

.DESCRIPTION
    Copies this project to F:\comp_demo-dist\comp_demo, excluding only generated
    caches and this session's build logs, then:

      1. validates the copy's compose file resolves (build context inside the copy)
      2. runs verify-all.ps1 FROM THE COPY, so the bundle proves itself (41 checks)
      3. zips the tree and writes SHA256.txt next to it

    Nothing outside comp_demo is read, so the copy is standalone.

.PARAMETER Dest
    Destination root. Default F:\comp_demo-dist

.PARAMETER SkipVerify
    Copy + zip only (no 41-check run).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File F:\ERPNEXT\erpnext-build\make-bundle.ps1
#>
[CmdletBinding()]
param(
    [string]$Dest = 'F:\erpnext-build-dist',
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Src = $PSScriptRoot
$Leaf = Split-Path $Src -Leaf                      # comp_demo
$Stamp = Get-Date -Format 'yyyy-MM-dd'
$Work = Join-Path $Dest $Leaf
$Zip = Join-Path $Dest ("{0}-{1}.zip" -f $Leaf, $Stamp)

function Step([string]$m) { Write-Host ''; Write-Host "== $m ==" -ForegroundColor Cyan }
function Info([string]$m) { Write-Host "  $m" }
function Warn([string]$m) { Write-Host "  WARN: $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# 1. clean copy
# ---------------------------------------------------------------------------
Step "copying $Src -> $Work"
if (Test-Path $Work) {
    # never delete blindly: only a directory that looks like a previous bundle
    $marker = Join-Path $Work 'docker-compose.yml'
    if (-not (Test-Path $marker)) { throw "refusing to delete $Work (no docker-compose.yml inside)" }
    Remove-Item $Work -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

# /XD  caches and VCS;  /XF generated logs from this session (keep verify-all-final.log)
$robo = & robocopy $Src $Work /E /XD __pycache__ .git /XF 'rebuild-*.log' 'up-run*.log' 'up-rerun*.log' '*.pyc' /NFL /NDL /NJH /NJS /NP
$code = $LASTEXITCODE
if ($code -ge 8) { throw "robocopy failed with code $code" }

$files = (Get-ChildItem $Work -Recurse -File | Measure-Object)
$sizeMb = [math]::Round(((Get-ChildItem $Work -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Info ("{0} files, {1} MB" -f $files.Count, $sizeMb)

# ---------------------------------------------------------------------------
# 2. the copy must resolve its own build context
# ---------------------------------------------------------------------------
Step 'validating the copy'
$composeExe = (Get-Command docker-compose -ErrorAction SilentlyContinue).Source
if (-not $composeExe) { $composeExe = 'docker' }
$composeArgs = @('-p', 'comp_demo', '--env-file', (Join-Path $Work '.env'), '-f', (Join-Path $Work 'docker-compose.yml'), 'config')
$config = & $composeExe @composeArgs 2>&1
if ($LASTEXITCODE -ne 0) { throw "compose config failed in the copy: $($config | Select-Object -Last 5)" }
$contextLine = ($config | Select-String -Pattern '^\s*context:' | Select-Object -First 1).Line
Info ("compose context: " + $contextLine.Trim())
if ($contextLine -notmatch [regex]::Escape($Work)) { throw "build context does not point inside the copy ($contextLine)" }

# ---------------------------------------------------------------------------
# 3. the copy proves itself
# ---------------------------------------------------------------------------
if (-not $SkipVerify) {
    Step 'running verify-all.ps1 from the copy (41 checks, ~5 min)'
    $log = Join-Path $Work 'verify-all-final.log'
    $out = & powershell.exe -ExecutionPolicy Bypass -NoProfile -File (Join-Path $Work 'verify-all.ps1') 2>&1
    $out | Set-Content -LiteralPath $log -Encoding UTF8
    $result = ($out | Select-String -Pattern 'RESULT:' | Select-Object -Last 1).Line
    if (-not $result) { throw 'verify-all.ps1 from the copy produced no RESULT line' }
    Info $result.Trim()
    if ($result -notmatch '0 failed') { throw "the copy did not pass: $result" }
} else {
    Warn 'verify skipped (-SkipVerify)'
}

# ---------------------------------------------------------------------------
# 4. zip + checksum
# ---------------------------------------------------------------------------
Step 'archiving'
if (Test-Path $Zip) { Remove-Item $Zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($Work, $Zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
$hash = (Get-FileHash $Zip -Algorithm SHA256).Hash
$zipMb = [math]::Round((Get-Item $Zip).Length / 1MB, 1)
"$hash  $Leaf-$Stamp.zip" | Set-Content -LiteralPath (Join-Path $Dest 'SHA256.txt') -Encoding ASCII
Info ("{0}  ({1} MB)" -f $Zip, $zipMb)
Info ("sha256: {0}" -f $hash)

Write-Host ''
Write-Host '  bundle ready' -ForegroundColor Green
Info ("folder : {0}" -f $Work)
Info ("archive: {0}" -f $Zip)
Info ("checksum: {0}" -f (Join-Path $Dest 'SHA256.txt'))
Write-Host ''
