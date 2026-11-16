<#
.SYNOPSIS
    One command to go from a fresh clone to a running comp_demo.

.DESCRIPTION
    This is the entry point for someone who has never seen the project. It does
    the minimum needed to get a working demo, in the order that actually works:

      1. create .env from .env.example when it is missing
      2. `docker compose create`      (pulls the bench image, or builds it once)
      3. start db + redis, wait for the database to be healthy
      4. run the one-shot `seed` service, wait for the restore to finish
      5. start bench / node-red / metabase / planner, wait for ERPNext to answer
      6. run `setup.ps1 -NonInteractive -SkipTunnel` to mint the API tokens and
         start the background jobs (skips Shopify and ngrok, which are optional)

    Shopify and ngrok are deliberately optional here: a colleague with no store
    and no tunnel still gets a complete local demo. Run `setup.ps1` again later
    after filling SHOPIFY_* in .env to switch those on.

.PARAMETER NoWiring
    Stop after the site answers. Skips the setup.ps1 converge (tokens + jobs), so
    the planner will return 401 until you run setup.ps1 yourself.

.PARAMETER Pull
    Force a re-pull of the published bench image, even when it is already on
    this machine. Pulling is the default on a first run; use -NoPull to skip it.

.PARAMETER NoPull
    Never contact GHCR: use a local image if present, otherwise build it.

.PARAMETER Recreate
    Recreate the stateless containers (node-red, metabase, planner). Volumes are
    never deleted by this script.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\start.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\start.ps1 -NoWiring
#>
param(
    [switch]$NoWiring,
    [switch]$Pull,
    [switch]$NoPull,
    [switch]$Recreate
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root
$ComposeFile = Join-Path $Root 'docker-compose.yml'
$EnvPath     = Join-Path $Root '.env'

function Say([string]$m)  { Write-Host "  ...   $m" }
function Ok([string]$m)   { Write-Host "  OK    $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "  WARN  $m" -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host "  FAIL  $m" -ForegroundColor Red }

function Read-Env([string]$Path) {
    $map = @{}
    if (Test-Path $Path) {
        foreach ($line in Get-Content $Path) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
                $map[$Matches[1]] = $Matches[2].Trim()
            }
        }
    }
    return $map
}

Write-Host ''
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Write-Host '  comp_demo - start' -ForegroundColor Cyan
Write-Host ('=' * 74) -ForegroundColor DarkCyan

# ---------------------------------------------------------------------------
# 1. prerequisites
# ---------------------------------------------------------------------------
if (-not (Test-Path $ComposeFile)) { Fail "no docker-compose.yml in $Root"; exit 1 }
$v = & docker version --format '{{.Server.Version}}' 2>&1
if ($LASTEXITCODE -ne 0) {
    Fail 'Docker engine is not reachable. Start Docker Desktop, wait for "Engine running", then rerun.'
    exit 1
}
Ok "docker engine $v"

if (-not (Test-Path $EnvPath)) {
    Copy-Item (Join-Path $Root '.env.example') $EnvPath -Force
    Ok '.env created from .env.example (no secrets needed for the local demo)'
} else {
    Ok '.env present'
}
$cfg = Read-Env $EnvPath
$Project  = if ($cfg['COMPOSE_PROJECT_NAME']) { $cfg['COMPOSE_PROJECT_NAME'] } else { 'comp_demo' }
$ErpPort  = if ($cfg['ERPNEXT_PORT'])  { $cfg['ERPNEXT_PORT'] }  else { '8000' }
$NrPort   = if ($cfg['NODE_RED_PORT']) { $cfg['NODE_RED_PORT'] } else { '1880' }
$PlanPort = if ($cfg['SCHEDULER_PORT']) { $cfg['SCHEDULER_PORT'] } else { '3001' }
$MbPort   = if ($cfg['METABASE_PORT']) { $cfg['METABASE_PORT'] } else { '3005' }
$Site     = if ($cfg['SITE_NAME'])     { $cfg['SITE_NAME'] } else { 'frontend' }
$BenchName = "$Project-bench-1"

# ---------------------------------------------------------------------------
# 2. containers
# ---------------------------------------------------------------------------
$existing = (& docker ps -a --format '{{.Names}}') 2>&1

# The 3 GB bench image is the only slow first-run step (25-40 min to build).
# CI publishes it to GHCR; pulling it takes a normal connection ~3-8 min. Try
# that BEFORE `compose create`, because compose silently builds instead when
# the tag is not local - which is exactly the "setup never finishes" report.
# Only treat BENCH_IMAGE as a registry ref when it has a namespace; a bare
# local tag like `comp_demo-bench:v16` is the compose default, not a pull target.
$GhcrImage = if ($cfg['BENCH_IMAGE'] -and $cfg['BENCH_IMAGE'] -match '/') { $cfg['BENCH_IMAGE'] } else { 'ghcr.io/msf4-0/comp-demo-bench:v16' }
$LocalTag  = 'comp_demo-bench:v16'
$haveImage = $false
& docker image inspect $LocalTag *> $null
if ($LASTEXITCODE -eq 0) { $haveImage = $true }

if (-not $NoPull -and (-not $haveImage -or $Pull)) {
    Say "pulling prebuilt bench image $GhcrImage (3 GB, one time)"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = cmd /c "docker pull --platform linux/amd64 $GhcrImage 2>&1"
    $rc = $LASTEXITCODE
    $out | Select-Object -Last 2 | ForEach-Object { Write-Host "        $_" }
    if ($rc -eq 0) {
        & docker tag $GhcrImage $LocalTag | Out-Null
        Ok ("bench image pulled in {0:n1} min" -f $sw.Elapsed.TotalMinutes)
        $haveImage = $true
    } else {
        Warn 'prebuilt image not pullable (package still private, or you are offline)'
        Warn '  one-time fix: https://github.com/msf4-0?tab=packages -> comp-demo-bench'
        Warn '                -> Package settings -> Change visibility -> Public'
        Warn '  falling back to a local build - 25-40 minutes, once'
    }
} elseif ($haveImage) {
    Ok "bench image present locally ($LocalTag)"
} else {
    Say 'skipping GHCR (-NoPull) - a local build will be used'
}

# If the containers are gone but host backups exist, this run will restore the
# seed snapshot - i.e. everything newer than the dump disappears. Say so first.
$backupDir = Join-Path $Root 'backups'
$volumes = (& docker volume ls --format '{{.Name}}') 2>&1
if (-not ($volumes -match [regex]::Escape("${Project}_db_data")) -and (Test-Path $backupDir) -and
    ((Get-ChildItem $backupDir -Directory | Measure-Object).Count -gt 0)) {
    Warn 'the db_data volume is gone but host backups exist:'
    Warn 'this run will restore seed/frontend-database.sql.gz, which is older than those backups.'
    Warn "to keep your data, restore instead:  powershell -File .\restore.ps1 -Backup <name>"
    $answer = Read-Host 'continue and seed a fresh site? [y/N]'
    if ($answer -notmatch '^(y|yes)$') { Fail 'aborted before touching volumes'; exit 1 }
}

if (-not ($existing -match [regex]::Escape($BenchName))) {
    if (-not $haveImage) {
        Warn 'the bench image is still not on this machine - the first run builds it once (25-40 minutes, ~3 GB)'
    }
    Say 'docker compose create'
    & docker compose --project-directory $Root create
    if ($LASTEXITCODE -ne 0) { Fail 'docker compose create failed - see the output above'; exit 1 }
}

if ($Recreate) {
    Say 'recreating node-red and planner (volumes untouched)'
    & docker compose --project-directory $Root rm -sf node-red scheduler 2>&1 | Out-Null
    & docker compose --project-directory $Root create node-red scheduler | Out-Null
}

# Already serving? Then this is a restart, not a first run.
$already = $false
try {
    $ping = Invoke-WebRequest "http://localhost:$ErpPort/api/method/ping" -UseBasicParsing -TimeoutSec 5
    $already = ($ping.StatusCode -eq 200)
} catch { $already = $false }

if (-not $already) {
    # db + redis first: the seeder and bench both need them up before they start.
    Say 'starting database and redis'
    & docker start "$Project-db-1" "$Project-redis-cache-1" "$Project-redis-queue-1" 2>&1 | Out-Null

    $deadline = (Get-Date).AddSeconds(150)
    do {
        Start-Sleep -Seconds 3
        $health = (& docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$Project-db-1") 2>&1
    } while ((Get-Date) -lt $deadline -and "$health" -ne 'healthy')
    if ("$health" -ne 'healthy') { Fail "database did not become healthy ($health)"; exit 1 }
    Ok 'database healthy'

    # The seed service restores the demo dump. It is a run-once container, so a
    # previous successful run means "already seeded" - do not restore twice.
    $seedState = (& docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$Project-seed-1" 2>$null) 2>&1
    if ("$seedState" -match '^exited 0') {
        Ok 'seed already completed - site data present'
    } else {
        Say 'seeding the demo database (one time, ~5-6 minutes)'
        & docker start "$Project-seed-1" 2>&1 | Out-Null
        $deadline = (Get-Date).AddSeconds(900)
        do {
            Start-Sleep -Seconds 5
            $seedState = (& docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$Project-seed-1" 2>$null) 2>&1
        } while ((Get-Date) -lt $deadline -and "$seedState" -match '^(running|created|restarting)')
        if ("$seedState" -notmatch '^exited 0') {
            Fail "seed did not finish cleanly ($seedState). Inspect: docker logs $Project-seed-1"
            exit 1
        }
        Ok 'site restored'
    }

    Say 'starting bench, node-red, metabase, planner'
    & docker start $BenchName "$Project-node-red-1" 2>&1 | Out-Null
    & docker start "$Project-metabase-1" "$Project-scheduler-1" 2>&1 | Out-Null

    $deadline = (Get-Date).AddSeconds(300)
    $ok = $false
    do {
        Start-Sleep -Seconds 5
        try {
            $r = Invoke-WebRequest "http://localhost:$ErpPort/api/method/ping" -UseBasicParsing -TimeoutSec 10
            $ok = ($r.StatusCode -eq 200)
        } catch { $ok = $false }
    } while ((Get-Date) -lt $deadline -and -not $ok)

    if (-not $ok) {
        # Classic fresh-volume symptom: bench serve started before the site existed.
        Warn 'ERPNext is not answering yet - restarting the bench container once'
        & docker restart $BenchName | Out-Null
        $deadline = (Get-Date).AddSeconds(180)
        do {
            Start-Sleep -Seconds 5
            try {
                $r = Invoke-WebRequest "http://localhost:$ErpPort/api/method/ping" -UseBasicParsing -TimeoutSec 10
                $ok = ($r.StatusCode -eq 200)
            } catch { $ok = $false }
        } while ((Get-Date) -lt $deadline -and -not $ok)
    }
    if (-not $ok) { Fail "ERPNext did not answer on :$ErpPort - check: docker logs $BenchName"; exit 1 }
}
Ok "ERPNext answers on http://localhost:$ErpPort"

# ---------------------------------------------------------------------------
# 3. tokens, background jobs, verification
# ---------------------------------------------------------------------------
if (-not $NoWiring) {
    Say 'wiring tokens and background jobs (setup.ps1 -NonInteractive -SkipTunnel)'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'setup.ps1') -NonInteractive -SkipTunnel
    if ($LASTEXITCODE -ne 0) {
        Warn "setup.ps1 reported problems (exit $LASTEXITCODE). The site still runs; see 'outstanding' above."
    }
} else {
    Warn 'skipped token wiring (-NoWiring) - the planner API will answer 401 until setup.ps1 runs'
}

# ---------------------------------------------------------------------------
# 4. what to do next
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 74) -ForegroundColor Green
Write-Host '  READY' -ForegroundColor Green
Write-Host ('=' * 74) -ForegroundColor Green
Write-Host "  ERPNext   http://localhost:$ErpPort    Administrator / admin  (site '$Site')"
Write-Host "            http://localhost:$ErpPort    demo@compdemo.local / demo  (non-admin)"
Write-Host "  Planner   http://localhost:$PlanPort"
Write-Host "  Node-RED  http://localhost:$NrPort"
Write-Host "  Metabase  http://localhost:$MbPort"
Write-Host ''
Write-Host '  optional integrations (off until configured):'
Write-Host '    Shopify  fill SHOPIFY_* in .env, then: .\setup.ps1'
Write-Host '    ngrok    install + "ngrok config add-authtoken <token>", then: .\setup.ps1'
Write-Host '  health check (read only):  .\setup.ps1 -VerifyOnly'
Write-Host ''
