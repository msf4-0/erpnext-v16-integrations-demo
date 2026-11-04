$ErrorActionPreference = 'Continue'
$log = 'F:\ERPNEXT\erpnextcomp_demo\bake\move-docker.log'
if (Test-Path $log) { Remove-Item $log -Force }
function Log($m) { $line = (Get-Date -Format 'HH:mm:ss') + '  ' + $m; Write-Host $line; Add-Content -LiteralPath $log -Value $line }

Log '=== Docker -> SSD move (elevated) ==='

# 1. stop Docker Desktop (processes + service)
Log 'Stopping Docker Desktop...'
Get-Service 'com.docker.service','Docker Desktop Service' -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
'Docker Desktop','com.docker.backend','com.docker.build','com.docker.dev-envs','com.docker.extensions','com.docker.cli','com.docker.proxy' | ForEach-Object {
    Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 6

# 2. wsl shutdown (releases the vhdx)
Log 'wsl --shutdown...'
wsl --shutdown 2>&1 | Out-Null
Start-Sleep -Seconds 10

# 3. compact the vhdx
$vhdx = 'F:\SHRDCPROJ\poc-desktop-agent\docker-wsl\disk\docker_data.vhdx'
if (Test-Path $vhdx) { Log ("vhdx before compact: " + [int]((Get-Item $vhdx).Length/1GB) + ' GB') } else { Log "ERROR: vhdx not found: $vhdx"; exit 1 }

Log 'Compacting via diskpart (this can take several minutes)...'
$ds = "$env:TEMP\compact-vhdx.dp"
$dpLines = @(
  ('select vdisk file="' + $vhdx + '"'),
  'compact vdisk',
  'exit'
)
Set-Content -LiteralPath $ds -Value $dpLines -Encoding ASCII
Add-Content -LiteralPath $log -Value (diskpart /s $ds 2>&1 | Out-String)
Start-Sleep -Seconds 3
$post = [int]((Get-Item $vhdx).Length/1GB)
Log ("vhdx after compact: " + $post + ' GB')

if ($post -gt 70) {
    Log "ABORT: vhdx still $post GB (>70GB) - compact failed, not moving."
    exit 2
}

# 4. move folder to C:
Log 'Moving docker-wsl folder to C:\Docker\docker-wsl ...'
New-Item -ItemType Directory -Force -Path 'C:\Docker' | Out-Null
Move-Item 'F:\SHRDCPROJ\poc-desktop-agent\docker-wsl' 'C:\Docker\docker-wsl'
Log 'move done'

# 5. update Docker Desktop settings
Log 'Updating settings-store.json...'
$s = "$env:APPDATA\Docker\settings-store.json"
$raw = Get-Content -LiteralPath $s -Raw
$raw = $raw.Replace('F:\\SHRDCPROJ\\poc-desktop-agent\\docker-wsl', 'C:\\Docker\\docker-wsl')
Set-Content -LiteralPath $s -Value $raw -Encoding UTF8 -NoNewline
Log 'settings updated'

Log '=== DONE - Docker data relocated to C:\Docker\docker-wsl ==='
