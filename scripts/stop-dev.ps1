$repoRoot = Split-Path -Parent $PSScriptRoot

function Write-Status {
    param([bool]$Ok, [string]$Label)
    $mark = if ($Ok) { '[ok]' } else { '[--]' }
    Write-Host "  $mark  $Label"
}

function Get-EncodedCommand([string]$CommandText) {
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($CommandText)
    return [Convert]::ToBase64String($bytes)
}

function Get-DevSessionStatePath {
    return Join-Path $env:TEMP 'classroomio-dev-session.json'
}

function Get-DevSessionState {
    $statePath = Get-DevSessionStatePath
    if (-not (Test-Path $statePath)) {
        return $null
    }

    try {
        return Get-Content $statePath -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Remove-DevSessionState {
    $statePath = Get-DevSessionStatePath
    if (Test-Path $statePath) {
        Remove-Item $statePath -Force -ErrorAction SilentlyContinue
    }
}

function Stop-PortProcess {
    param([int]$Port, [string]$Name)
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $conns) {
        Write-Status -Ok $false -Label "$Name not running on port $Port"
        return
    }
    foreach ($conn in $conns) {
        taskkill /F /PID $conn.OwningProcess /T 2>$null | Out-Null
    }
    Write-Status -Ok $true -Label "$Name stopped (port $Port)"
}

function Stop-DevBrowserProcess {
    $dashboardUrl = 'http://localhost:5173'
    $browserProcesses = Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and
        $_.CommandLine -like "*--app=$dashboardUrl*" -and
        ($_.Name -eq 'msedge.exe' -or $_.Name -eq 'chrome.exe')
    }

    if (-not $browserProcesses) {
        Write-Status -Ok $false -Label 'Dev browser window not running'
        return
    }

    foreach ($process in $browserProcesses) {
        taskkill /F /PID $process.ProcessId /T 2>$null | Out-Null
    }

    Write-Status -Ok $true -Label 'Dev browser window closed'
}

function Stop-DevTerminalProcesses {
    $state = Get-DevSessionState
    if ($state -and $state.TerminalProcessIds) {
        $trackedProcesses = @($state.TerminalProcessIds | ForEach-Object {
            Get-Process -Id $_ -ErrorAction SilentlyContinue
        } | Where-Object { $_ })

        if ($trackedProcesses.Count -gt 0) {
            foreach ($process in $trackedProcesses) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }

            Remove-DevSessionState
            Write-Status -Ok $true -Label "$($trackedProcesses.Count) tracked dev terminal process(es) closed"
            return
        }
    }

    $apiCommand = Get-EncodedCommand "Set-Location '$repoRoot'; corepack pnpm api:dev"
    $dashboardCommand = Get-EncodedCommand "Set-Location '$repoRoot'; corepack pnpm dashboard:dev"

    $terminalProcesses = Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and
        (
            (
                ($_.Name -eq 'pwsh.exe' -or $_.Name -eq 'powershell.exe') -and (
                    $_.CommandLine -like "*$apiCommand*" -or
                    $_.CommandLine -like "*$dashboardCommand*"
                )
            ) -or
            (
                ($_.Name -eq 'WindowsTerminal.exe' -or $_.Name -eq 'wt.exe') -and (
                    $_.CommandLine -like "*$apiCommand*" -or
                    $_.CommandLine -like "*$dashboardCommand*"
                )
            )
        )
    }

    if (-not $terminalProcesses) {
        Remove-DevSessionState
        Write-Status -Ok $false -Label 'Dev PowerShell terminals not running'
        return
    }

    foreach ($process in $terminalProcesses) {
        taskkill /F /PID $process.ProcessId /T 2>$null | Out-Null
    }

    Remove-DevSessionState
    Write-Status -Ok $true -Label "$($terminalProcesses.Count) dev PowerShell terminal(s) closed"
}

function Stop-DockerDesktop {
    $dockerProcessNames = @('Docker Desktop', 'com.docker.backend', 'com.docker.proxy', 'com.docker.build', 'com.docker.dev-envs')
    $dockerProcesses = Get-Process -Name $dockerProcessNames -ErrorAction SilentlyContinue

    if (-not $dockerProcesses) {
        Write-Status -Ok $false -Label 'Docker Desktop not running'
        return
    }

    # Graceful shutdown on the main UI window first
    $mainProc = $dockerProcesses | Where-Object { $_.Name -eq 'Docker Desktop' } | Select-Object -First 1
    if ($mainProc -and $mainProc.MainWindowHandle -ne 0) {
        [void]$mainProc.CloseMainWindow()
        [void]$mainProc.WaitForExit(15000)
    }

    # Force-kill anything still running
    Get-Process -Name $dockerProcessNames -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # Wait up to 5 s for all processes to fully exit
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Process -Name $dockerProcessNames -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }

    # Terminate WSL2 Docker distros so they don't block a clean restart
    wsl --terminate docker-desktop      *>$null
    wsl --terminate docker-desktop-data *>$null

    Write-Status -Ok $true -Label 'Docker Desktop closed'
}

Write-Host ''
Write-Host 'Stopping ClassroomIO dev environment'
Write-Host ''

# --- Dev servers ---
Write-Host 'Dev servers'
Stop-PortProcess -Port 3002 -Name 'API'
Stop-PortProcess -Port 5173 -Name 'Dashboard'
Write-Host ''

# --- Orphaned background processes (turbo, tsx, vite, pnpm runners) ---
$repoRootLower = $repoRoot.ToLower()

$orphanedNode = Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {
    $cl = $_.CommandLine
    $cl -and $cl.ToLower() -like "*$repoRootLower*" -and (
        $cl -like '*pnpm*' -or
        $cl -like '*turbo*' -or
        $cl -like '*tsx*' -or
        $cl -like '*vite*' -or
        $cl -like '*api:dev*' -or
        $cl -like '*dashboard:dev*'
    )
}

$orphanedTurbo = Get-CimInstance Win32_Process | Where-Object {
    $_.Name -like 'turbo*' -and
    $_.CommandLine -and
    $_.CommandLine.ToLower() -like "*$repoRootLower*"
}

$orphans = @($orphanedNode) + @($orphanedTurbo) | Where-Object { $_ -ne $null }

if ($orphans.Count -gt 0) {
    Write-Host 'Background processes'
    foreach ($p in $orphans) {
        taskkill /F /PID $p.ProcessId /T 2>$null | Out-Null
    }
    Write-Status -Ok $true -Label "$($orphans.Count) orphaned process(es) cleaned up"
    Write-Host ''
}

# --- Dev browser + terminals ---
Write-Host 'Desktop apps'
Stop-DevBrowserProcess
Stop-DevTerminalProcesses
Write-Host ''

# --- Docker containers ---
Write-Host 'Infrastructure'
if (Get-Command docker -ErrorAction SilentlyContinue) {
    docker info *> $null
    if ($LASTEXITCODE -eq 0) {
        docker compose -f "$repoRoot/docker/docker-compose.yaml" stop postgres redis *> $null
        Write-Status -Ok $true -Label 'Postgres and Redis stopped'
        Stop-DockerDesktop
    }
    else {
        Write-Status -Ok $false -Label 'Docker daemon not running — containers already stopped'
        Stop-DockerDesktop
    }
}
else {
    Write-Status -Ok $false -Label 'Docker not installed'
}

Write-Host ''
Write-Host 'Dev environment stopped.'
Write-Host ''
