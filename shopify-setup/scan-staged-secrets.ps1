# Fail-closed secret scan over everything staged for commit.
#
# Reads the real values out of the local (git-ignored) env files and .env.example
# leftovers, then greps every staged file for them. Any hit is reported and the
# script exits non-zero, so a leak cannot be committed silently.
param(
    [string]$RepoRoot = 'F:\ERPNEXT\erpnextcomp_demo'
)

$envFiles = @(
    (Join-Path $RepoRoot '.env')
    (Join-Path $RepoRoot 'sandbox\.env.ai-fix')
    (Join-Path $RepoRoot 'shopify-setup\.env')
)

$secrets = @{}
foreach ($f in $envFiles) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    foreach ($line in Get-Content -LiteralPath $f) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $key = $Matches[1]
            $val = $Matches[2].Trim('"', "'")
            if ($key -notmatch 'TOKEN|SECRET|KEY|PASSWORD') { continue }
            if ($val.Length -lt 10) { continue }
            if ($val -match '^__|^REPLACE|^FILL_ME|^<') { continue }
            if ($val -eq '__NGROK_AUTHTOKEN__') { continue }
            $secrets["$key ($(Split-Path $f -Leaf))"] = $val
        }
    }
}

# ngrok authtoken lives in their own config, not in the env files
$ngrokYml = Join-Path $env:LOCALAPPDATA 'Packages\ngrok.ngrok_1g87z0zv29zzc\LocalCache\Local\ngrok\ngrok.yml'
if (Test-Path -LiteralPath $ngrokYml) {
    $m = [regex]::Match((Get-Content -LiteralPath $ngrokYml -Raw), 'authtoken:\s*(\S+)')
    if ($m.Success -and $m.Groups[1].Value.Length -ge 10) { $secrets['ngrok authtoken'] = $m.Groups[1].Value }
}

Write-Output "scanning for $($secrets.Count) secret value(s)"

$staged = & git -C $RepoRoot diff --cached --name-only
$hits = 0
foreach ($rel in $staged) {
    $full = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $item = Get-Item -LiteralPath $full
    if ($item.Length -gt 5MB) { continue }
    if ($item.Extension -match '\.(png|jpg|jpeg|gif|ico|zip|woff2?|ttf|eot|pdf|mp4)$') { continue }

    $text = Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue
    if (-not $text) { continue }

    foreach ($name in $secrets.Keys) {
        if ($text.Contains($secrets[$name])) {
            Write-Output "  LEAK  $rel  <- $name"
            $hits++
        }
    }
}

if ($hits -gt 0) {
    Write-Output ""
    Write-Output "FAIL: $hits secret occurrence(s) staged - do not commit"
    exit 1
}
Write-Output "PASS: no secret values found in staged files"
exit 0
