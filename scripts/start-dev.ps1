param(
    [switch]$WithMinio
)

$repoRoot = Split-Path -Parent $PSScriptRoot

# Install pnpm shim so subprocesses spawned by pnpm scripts can find `pnpm` directly.
# Without this, `corepack pnpm` works but pnpm's internal cmd /c calls fail.
Write-Host 'Enabling corepack shims...'
corepack enable

Write-Host 'Installing dependencies...'
Set-Location $repoRoot
corepack pnpm install

Write-Host ''
Write-Host 'Starting infrastructure (Postgres + Redis)...'
if (Get-Command docker -ErrorAction SilentlyContinue) {
    docker info *> $null
    if ($LASTEXITCODE -eq 0) {
        $dockerServices = @('postgres', 'redis')
        if ($WithMinio) { $dockerServices += @('minio', 'minio-init') }
        docker compose -f "$repoRoot/docker/docker-compose.yaml" up -d @dockerServices
        Write-Host -NoNewline 'Waiting for Postgres and Redis to be healthy'
        $dbAttempts = 0
        $pgHealthy = $false
        $redisHealthy = $false
        while ($dbAttempts -lt 24) {
            $pgHealthy = (docker inspect --format='{{.State.Health.Status}}' cio-postgres 2>$null) -eq 'healthy'
            $redisHealthy = (docker inspect --format='{{.State.Health.Status}}' cio-redis    2>$null) -eq 'healthy'
            if ($pgHealthy -and $redisHealthy) { break }
            Start-Sleep -Seconds 5
            $dbAttempts++
            Write-Host -NoNewline '.'
        }
        Write-Host ''
        if (-not ($pgHealthy -and $redisHealthy)) {
            Write-Host 'WARNING: Postgres/Redis did not become healthy within 2 minutes. The API may fail to connect.'
        }
    }
    else {
        Write-Host 'WARNING: Docker daemon is not running. Start Docker Desktop and rerun this script.'
        exit 1
    }
}
else {
    Write-Host 'WARNING: Docker is not installed. Postgres and Redis will not be available.'
}

$apiEnvPath = Join-Path $repoRoot 'apps/api/.env'
$dbUrl = $null
if (Test-Path $apiEnvPath) {
    foreach ($line in (Get-Content $apiEnvPath)) {
        if ($line -match '^DATABASE_URL=(.+)$') {
            $dbUrl = $Matches[1].Trim()
            break
        }
    }
}
if (-not $dbUrl) {
    $dbUrl = 'postgresql://postgres:postgres@localhost:5432/classroomio'
}
$env:DATABASE_URL = $dbUrl

Write-Host ''
Write-Host 'Setting up database schema and seed data...'
corepack pnpm --filter @cio/db db:setup:seed
if ($LASTEXITCODE -ne 0) {
    Write-Host 'WARNING: Database setup failed. The app may not work correctly.'
    Write-Host 'Run manually: corepack pnpm --filter @cio/db db:setup:seed'
} else {
    Write-Host ''
    Write-Host 'Demo login credentials:'
    Write-Host '  Email:    admin@test.com'
    Write-Host '  Password: 123456'
}

function Test-Port {
    param([int]$Port)
    foreach ($addr in @('127.0.0.1', '::1')) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $async = $client.BeginConnect($addr, $Port, $null, $null)
            $ok = $async.AsyncWaitHandle.WaitOne(500)
            $client.Close()
            if ($ok) { return $true }
        }
        catch {}
    }
    return $false
}

function Get-EncodedCommand([string]$cmd) {
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($cmd)
    return [Convert]::ToBase64String($bytes)
}

function Get-DevSessionStatePath {
    return Join-Path $env:TEMP 'classroomio-dev-session.json'
}

function Save-DevSessionState {
    param([int[]]$TerminalProcessIds)

    $statePath = Get-DevSessionStatePath
    $terminalIds = @($TerminalProcessIds | Where-Object { $_ })

    $state = @{
        TerminalProcessIds = $terminalIds
        UpdatedAt          = (Get-Date).ToString('o')
    }

    $state | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8
}

function Get-DevBrowserLaunchSpec {
    $browserCandidates = @(
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
    ) | Where-Object { $_ -and (Test-Path $_) }

    $browserPath = $browserCandidates | Select-Object -First 1
    if (-not $browserPath) {
        return $null
    }

    return @{
        BrowserPath = $browserPath
    }
}

function Open-DevBrowser {
    param([string]$Url)

    $browserSpec = Get-DevBrowserLaunchSpec
    if (-not $browserSpec) {
        Start-Process $Url
        return
    }

    Start-Process $browserSpec.BrowserPath -ArgumentList @(
        '--new-window',
        "--app=$Url"
    )
}

$shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }

$apiEnc = Get-EncodedCommand "Set-Location '$repoRoot'; corepack pnpm api:dev"
$dashboardEnc = Get-EncodedCommand "Set-Location '$repoRoot'; corepack pnpm dashboard:dev"

Write-Host ''
Write-Host 'Starting ClassroomIO dev servers...'
Write-Host ''

if (Get-Command wt -ErrorAction SilentlyContinue) {
    Write-Host 'Opening tabs in Windows Terminal...'
    $terminalProcess = Start-Process wt -ArgumentList @(
        '-w', 'new',
        'new-tab', '--title', 'API', $shell, '-NoExit', '-EncodedCommand', $apiEnc,
        ';',
        'new-tab', '--title', 'Dashboard', $shell, '-NoExit', '-EncodedCommand', $dashboardEnc
    ) -PassThru

    Save-DevSessionState -TerminalProcessIds @($terminalProcess.Id)
}
else {
    Write-Host 'Windows Terminal not found. Opening separate PowerShell windows...'
    $apiProcess = Start-Process $shell -ArgumentList @('-NoExit', '-EncodedCommand', $apiEnc) -PassThru
    $dashboardProcess = Start-Process $shell -ArgumentList @('-NoExit', '-EncodedCommand', $dashboardEnc) -PassThru

    Save-DevSessionState -TerminalProcessIds @($apiProcess.Id, $dashboardProcess.Id)
}

Write-Host ''
Write-Host -NoNewline 'Waiting for API and Dashboard to be ready'
$timeout = 72  # 72 × 5 s = 6 minutes
$elapsed = 0
$browserOpened = $false
while ($elapsed -lt $timeout) {
    $apiReady = Test-Port 3002
    $dashboardReady = Test-Port 5173
    if ($apiReady -and $dashboardReady) {
        if (-not $browserOpened) {
            Open-DevBrowser -Url 'http://localhost:5173'
            $browserOpened = $true
        }

        break
    }

    Start-Sleep -Seconds 5
    $elapsed++
    Write-Host -NoNewline '.'
    if (-not $browserOpened -and $elapsed -ge 4) {
        Open-DevBrowser -Url 'http://localhost:5173'
        $browserOpened = $true
    }
}
Write-Host ''

if ((Test-Port 3002) -and (Test-Port 5173)) {
    Write-Host ''
    Write-Host 'Both services are ready:'
    Write-Host '  API:       http://localhost:3002'
    Write-Host '  Dashboard: http://localhost:5173'
    if ($WithMinio) {
        Write-Host '  MinIO:     http://localhost:9001  (user: minioadmin / minioadmin)'
    }
    Write-Host ''
}
else {
    Write-Host ''
    Write-Host 'WARNING: One or more services did not become ready within 6 minutes.'
    Write-Host '  API:       http://localhost:3002'
    Write-Host '  Dashboard: http://localhost:5173'
    Write-Host 'Check the terminal windows for errors.'
    Write-Host ''
}
