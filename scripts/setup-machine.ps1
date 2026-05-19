param(
    [switch]$DryRun,
    [switch]$SkipDevSetup
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$nvmrcPath = Join-Path $repoRoot '.nvmrc'
$requiredNodeVersion = $null
if (Test-Path $nvmrcPath) {
    $requiredNodeVersion = (Get-Content $nvmrcPath -Raw).Trim().TrimStart('v')
}

$machineChanges = [System.Collections.Generic.List[string]]::new()
$nextSteps = [System.Collections.Generic.List[string]]::new()
$plannedActions = [System.Collections.Generic.List[string]]::new()
$failures = [System.Collections.Generic.List[string]]::new()

function Test-CommandAvailable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-Step {
    param(
        [string]$Description,
        [string]$Command,
        [string[]]$Arguments
    )

    if ($DryRun) {
        $plannedActions.Add(($Description + ': ' + ($Command + ' ' + ($Arguments -join ' '))))
        return $true
    }

    Write-Host "`n$Description..."
    & $Command @Arguments
    return ($LASTEXITCODE -eq 0)
}

function Test-DockerReady {
    if (-not (Test-CommandAvailable 'docker')) {
        return $false
    }

    docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

function Start-DockerDesktop {
    $dockerExe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerExe) {
        Start-Process $dockerExe
        return $true
    }
    return $false
}

function Get-CurrentNodeVersion {
    if (-not (Test-CommandAvailable 'node')) {
        return $null
    }

    return (node -v).Trim()
}

function Write-CheckItem {
    param([bool]$Ok, [string]$Label)
    $mark = if ($Ok) { '[ok]' } else { '[--]' }
    Write-Host "  $mark  $Label"
}

function Set-EnvValue {
    param([string]$FilePath, [string]$Key, [string]$Value)
    $lines = (Get-Content $FilePath -ErrorAction SilentlyContinue) ?? @()
    $pattern = "^$([regex]::Escape($Key))="
    $newLine = "$Key=$Value"
    $found = $false
    $updated = @()
    foreach ($line in $lines) {
        if ($line -match $pattern) { $found = $true; $updated += $newLine } else { $updated += $line }
    }
    if (-not $found) { $updated += $newLine }
    Set-Content $FilePath -Value $updated
}

# --- Header ---
Write-Host ''
Write-Host 'ClassroomIO machine setup'
Write-Host "Dry run: $(if ($DryRun) { 'yes' } else { 'no' })"
Write-Host ''

# --- Prerequisite status ---
$nvmAvailable      = Test-CommandAvailable 'nvm'
$dockerInstalled   = Test-CommandAvailable 'docker'
$dockerReady       = Test-DockerReady
$corepackAvailable = Test-CommandAvailable 'corepack'
$currentNodeVersion = Get-CurrentNodeVersion
$nodeVersionOk = $currentNodeVersion -and $requiredNodeVersion -and ($currentNodeVersion -eq "v$requiredNodeVersion")

$nodeLabel = if ($nodeVersionOk) {
    "Node $currentNodeVersion"
} elseif ($currentNodeVersion) {
    "Node $currentNodeVersion (required: v$requiredNodeVersion)"
} elseif ($requiredNodeVersion) {
    "Node (required: v$requiredNodeVersion, not active)"
} else {
    "Node (not active)"
}

Write-Host 'Prerequisite status'
Write-CheckItem -Ok (Test-CommandAvailable 'winget') -Label 'winget'
Write-CheckItem -Ok $nvmAvailable                    -Label 'nvm'
Write-CheckItem -Ok $nodeVersionOk                   -Label $nodeLabel
Write-CheckItem -Ok $corepackAvailable               -Label 'corepack'
Write-CheckItem -Ok $dockerInstalled                 -Label 'Docker installed'
Write-CheckItem -Ok $dockerReady                     -Label 'Docker daemon ready'
Write-Host ''

# --- Install missing prerequisites ---
if (-not (Test-CommandAvailable 'winget')) {
    $failures.Add('winget is not available. Cannot install prerequisites automatically. Install NVM for Windows and Docker Desktop manually, then run this script again.')
}

$installedNvmNow    = $false
$installedDockerNow = $false

if (-not $nvmAvailable -and -not $failures.Count) {
    if (Invoke-Step 'Installing NVM for Windows' 'winget' @('install', '--id', 'CoreyButler.NVMforWindows', '-e', '--accept-package-agreements', '--accept-source-agreements')) {
        if (-not $DryRun) {
            $installedNvmNow = $true
            $machineChanges.Add('Installed NVM for Windows.')
        }
    }
    else {
        $failures.Add('Installing NVM for Windows failed. Try running this script as Administrator.')
    }
}

if (-not $dockerInstalled -and -not $failures.Count) {
    if (Invoke-Step 'Installing Docker Desktop' 'winget' @('install', '--id', 'Docker.DockerDesktop', '-e', '--accept-package-agreements', '--accept-source-agreements')) {
        if (-not $DryRun) {
            $installedDockerNow = $true
            $machineChanges.Add('Installed Docker Desktop.')
        }
    }
    else {
        $failures.Add('Installing Docker Desktop failed. Try running this script as Administrator.')
    }
}

# --- Activate correct Node version ---
if (-not $DryRun -and -not $installedNvmNow -and (Test-CommandAvailable 'nvm') -and $requiredNodeVersion) {
    $nvmList = nvm list 2>$null | Out-String
    if ($nvmList -notmatch [regex]::Escape($requiredNodeVersion)) {
        if (Invoke-Step "Installing Node $requiredNodeVersion" 'nvm' @('install', $requiredNodeVersion)) {
            $machineChanges.Add("Installed Node $requiredNodeVersion.")
        }
        else {
            $failures.Add("Installing Node $requiredNodeVersion failed.")
        }
    }

    if (-not $failures.Count -and -not $nodeVersionOk) {
        if (Invoke-Step "Activating Node $requiredNodeVersion" 'nvm' @('use', $requiredNodeVersion)) {
            $machineChanges.Add("Activated Node $requiredNodeVersion.")
        }
        else {
            $failures.Add("Activating Node $requiredNodeVersion failed. Try running this script as Administrator (nvm use requires elevated permissions on Windows).")
        }
    }
}

# --- If we just installed NVM or Docker, PATH is stale — must reopen terminal ---
if (-not $DryRun -and ($installedNvmNow -or $installedDockerNow)) {
    $nextSteps.Add('Close this terminal and open a fresh one so the new PATH entries are available.')
    $nextSteps.Add('Start Docker Desktop and wait until its icon in the taskbar shows it is running.')
    $nextSteps.Add('Then run .\scripts\setup-machine.ps1 again to continue.')
}

# --- Run repo dev setup if all prerequisites are in place ---
$devSetupRan = $false

if (-not $DryRun -and -not $installedNvmNow -and -not $installedDockerNow -and -not $failures.Count) {
    if (-not (Test-CommandAvailable 'corepack')) {
        $failures.Add('corepack is not available. Make sure the correct Node version is active (nvm use) then run this script again.')
    }

    if (-not (Test-DockerReady)) {
        # Clear any processes and WSL distros left over from a previous stop
        $lingering = Get-Process -Name 'Docker Desktop', 'com.docker.backend', 'com.docker.proxy', 'com.docker.build', 'com.docker.dev-envs' -ErrorAction SilentlyContinue
        if ($lingering) {
            $lingering | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        wsl --terminate docker-desktop      *>$null
        wsl --terminate docker-desktop-data *>$null

        Write-Host 'Docker Desktop is not running. Attempting to start it...'
        if (Start-DockerDesktop) {
            Write-Host -NoNewline 'Waiting for Docker to be ready'
            $attempts = 0
            while (-not (Test-DockerReady) -and $attempts -lt 24) {
                Start-Sleep -Seconds 5
                $attempts++
                Write-Host -NoNewline '.'
            }
            Write-Host ''
        }

        if (-not (Test-DockerReady)) {
            $failures.Add('Docker Desktop is not ready. Start Docker Desktop, wait until its taskbar icon shows it is running, then run .\scripts\setup-machine.ps1 again.')
        }
    }

    if (-not $SkipDevSetup -and -not $failures.Count) {
        if (Invoke-Step 'Running repository dev setup' 'corepack' @('pnpm', 'setup:dev')) {
            $devSetupRan = $true
        }
        else {
            $failures.Add('Repository dev setup failed. Check the output above for details, then run this script again.')
        }
    }
}

# --- Output summary ---
if ($plannedActions.Count -gt 0) {
    Write-Host 'Planned actions'
    $plannedActions | ForEach-Object { Write-Host "  - $_" }
    Write-Host ''
}

if ($machineChanges.Count -gt 0) {
    Write-Host 'Changes made'
    $machineChanges | ForEach-Object { Write-Host "  - $_" }
    Write-Host ''
}

if ($nextSteps.Count -gt 0) {
    Write-Host 'Next steps'
    $nextSteps | ForEach-Object { Write-Host "  - $_" }
    Write-Host ''
    exit 0
}

if ($failures.Count -gt 0) {
    Write-Host 'Action required'
    $failures | ForEach-Object { Write-Host "  - $_" }
    Write-Host ''
    exit 1
}

if ($devSetupRan) {
    Write-Host 'Setup complete!'
    Write-Host ''
    $startAnswer = Read-Host 'Start the dev servers now? (Y/n)'
    $minioAnswer = Read-Host 'Enable MinIO for local file storage (needed for file upload features)? (y/N)'

    $startServers = ($startAnswer -eq '' -or $startAnswer -match '^[Yy]')
    $withMinio    = ($minioAnswer -match '^[Yy]')

    $apiEnvPath = Join-Path $repoRoot 'apps/api/.env'
    $hasAiKey = $false
    if (Test-Path $apiEnvPath) {
        $apiEnvContent = Get-Content $apiEnvPath -Raw
        $hasAiKey = $apiEnvContent -match '(?m)^(OPENAI_API_KEY|GOOGLE_API_KEY|ANTHROPIC_API_KEY)=\S+'
    }

    if (-not $hasAiKey) {
        Write-Host ''
        Write-Host 'AI features are disabled by default. Enter an API key to enable them, or press Enter to skip each one.'
        $googleKey    = Read-Host '  Google API key    (Gemini 2.5 Flash - recommended)'
        $openaiKey    = Read-Host '  OpenAI API key    (GPT-4o)'
        $anthropicKey = Read-Host '  Anthropic API key (Claude)'

        foreach ($pair in @(
            [pscustomobject]@{ Key = 'GOOGLE_API_KEY';    Value = $googleKey },
            [pscustomobject]@{ Key = 'OPENAI_API_KEY';    Value = $openaiKey },
            [pscustomobject]@{ Key = 'ANTHROPIC_API_KEY'; Value = $anthropicKey }
        )) {
            if ($pair.Value -and $pair.Value.Trim()) {
                Set-EnvValue -FilePath $apiEnvPath -Key $pair.Key -Value $pair.Value.Trim()
            }
        }
    }

    if ($startServers) {
        $startArgs = @()
        if ($withMinio) { $startArgs += '-WithMinio' }
        & (Join-Path $PSScriptRoot 'start-dev.ps1') @startArgs
    }
    else {
        Write-Host ''
        Write-Host 'You can start them later by running:'
        if ($withMinio) {
            Write-Host '  .\scripts\start-dev.ps1 -WithMinio'
        } else {
            Write-Host '  .\scripts\start-dev.ps1'
        }
        Write-Host ''
    }
}
elseif ($DryRun) {
    Write-Host 'Dry run complete. Run without -DryRun to apply the changes above.'
    Write-Host ''
}
elseif ($SkipDevSetup) {
    Write-Host 'Machine prerequisites are ready. Run .\scripts\setup-machine.ps1 to complete repo setup.'
    Write-Host ''
}
