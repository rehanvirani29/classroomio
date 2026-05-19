const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const repoRoot = path.resolve(__dirname, '..');
const args = new Set(process.argv.slice(2));
const dryRun = args.has('--dry-run');
const skipDevSetup = args.has('--skip-dev-setup');

function commandExists(command) {
  const probe = process.platform === 'win32' ? 'where' : 'which';
  const result = spawnSync(probe, [command], { stdio: 'ignore' });
  return result.status === 0;
}

function runCommand(command, commandArgs, options = {}) {
  const result = spawnSync(command, commandArgs, {
    cwd: repoRoot,
    stdio: 'inherit',
    shell: process.platform === 'win32',
    ...options
  });

  return result.status ?? 1;
}

function readRequiredNodeVersion() {
  const versionPath = path.join(repoRoot, '.nvmrc');
  if (!fs.existsSync(versionPath)) {
    return null;
  }

  return fs.readFileSync(versionPath, 'utf8').trim().replace(/^v/, '');
}

function printSection(title, items) {
  if (items.length === 0) {
    return;
  }

  console.log(`\n${title}`);
  for (const item of items) {
    console.log(`- ${item}`);
  }
}

function maybeRun(command, commandArgs, description, state) {
  if (dryRun) {
    state.plannedActions.push(`${description}: ${[command, ...commandArgs].join(' ')}`);
    return 0;
  }

  console.log(`\n${description}...`);
  const status = runCommand(command, commandArgs);
  if (status !== 0) {
    state.failures.push(`${description} failed with exit code ${status}.`);
  }

  return status;
}

function isDockerReady() {
  if (!commandExists('docker')) {
    return false;
  }

  const result = spawnSync('docker', ['info'], { stdio: 'ignore' });
  return result.status === 0;
}

function hasNodeVersion(requiredVersion) {
  if (!commandExists('nvm')) {
    return false;
  }

  const result = spawnSync('nvm', ['list'], { encoding: 'utf8' });
  return result.status === 0 && result.stdout.includes(requiredVersion);
}

function gatherWindowsState(requiredVersion) {
  return {
    hasWinget: commandExists('winget'),
    hasDocker: commandExists('docker'),
    dockerReady: isDockerReady(),
    hasNvm: commandExists('nvm'),
    hasRequiredNode: requiredVersion ? hasNodeVersion(requiredVersion) : true,
    currentNode: process.version,
    hasCorepack: commandExists('corepack')
  };
}

if (process.platform !== 'win32') {
  console.error('setup:machine currently supports Windows automation only.');
  process.exit(1);
}

const requiredNodeVersion = readRequiredNodeVersion();
const state = {
  failures: [],
  machineChanges: [],
  notes: [],
  plannedActions: [],
  nextSteps: []
};

const windowsState = gatherWindowsState(requiredNodeVersion);

if (!windowsState.hasWinget) {
  state.failures.push('winget is not available, so machine dependencies cannot be installed automatically.');
}

if (windowsState.hasWinget && !windowsState.hasNvm) {
  const status = maybeRun(
    'winget',
    ['install', '--id', 'CoreyButler.NVMforWindows', '-e', '--accept-package-agreements', '--accept-source-agreements'],
    'Installing NVM for Windows',
    state
  );
  if (!dryRun && status === 0) {
    state.machineChanges.push('Installed NVM for Windows.');
    state.notes.push('Open a new terminal after NVM for Windows installs so the nvm command is available.');
  } else if (dryRun) {
    state.notes.push('Open a new terminal after NVM for Windows installs so the nvm command is available.');
  }
}

const nvmAvailable = commandExists('nvm');
if (requiredNodeVersion && nvmAvailable && !windowsState.hasRequiredNode) {
  const status = maybeRun('nvm', ['install', requiredNodeVersion], `Installing Node ${requiredNodeVersion}`, state);
  if (!dryRun && status === 0) {
    state.machineChanges.push(`Installed Node ${requiredNodeVersion}.`);
  }
}

if (requiredNodeVersion && nvmAvailable) {
  state.nextSteps.push(`Run 'nvm use ${requiredNodeVersion}' in a fresh terminal before starting the app.`);
}

if (windowsState.hasWinget && !windowsState.hasDocker) {
  const status = maybeRun(
    'winget',
    ['install', '--id', 'Docker.DockerDesktop', '-e', '--accept-package-agreements', '--accept-source-agreements'],
    'Installing Docker Desktop',
    state
  );
  if (!dryRun && status === 0) {
    state.machineChanges.push('Installed Docker Desktop.');
    state.notes.push('Docker Desktop may require elevation and a reboot/WSL setup before the daemon is usable.');
  } else if (dryRun) {
    state.notes.push('Docker Desktop may require elevation and a reboot/WSL setup before the daemon is usable.');
  }
}

if (!dryRun) {
  if (state.machineChanges.length > 0) {
    state.nextSteps.push('Close this terminal and open a fresh one so new PATH entries are available.');
    if (requiredNodeVersion) {
      state.nextSteps.push(`Run 'nvm use ${requiredNodeVersion}' in the new terminal.`);
    }
    state.nextSteps.push('Start Docker Desktop and wait for the daemon to be ready.');
    if (!skipDevSetup) {
      state.nextSteps.push('After that, rerun: corepack pnpm setup:dev');
    }
  }

  const refreshedState = gatherWindowsState(requiredNodeVersion);
  if (!refreshedState.hasDocker) {
    state.failures.push('Docker is still not available on PATH after setup.');
  } else if (!refreshedState.dockerReady) {
    state.failures.push(
      'Docker Desktop is installed but the daemon is not ready. Launch Docker Desktop and wait for it to finish starting.'
    );
  }

  if (!refreshedState.hasCorepack) {
    state.failures.push('corepack is not available on PATH.');
  }

  if (!skipDevSetup && state.failures.length === 0 && state.machineChanges.length === 0) {
    console.log('\nRunning repository dev setup...');
    const status = runCommand('node', ['./scripts/dev-setup.cjs', '--strict']);
    if (status !== 0) {
      state.failures.push(`Repository dev setup failed with exit code ${status}.`);
    }
  } else if (!skipDevSetup && state.machineChanges.length === 0) {
    state.nextSteps.push('After Docker and Node are ready, run: corepack pnpm setup:dev');
  }
}

console.log('ClassroomIO machine setup');
console.log(`- Required Node: ${requiredNodeVersion ? `v${requiredNodeVersion}` : 'not specified'}`);
console.log(`- Current Node: ${process.version}`);
console.log(`- Dry run: ${dryRun ? 'yes' : 'no'}`);

printSection('Planned actions', state.plannedActions);
printSection('Machine changes', state.machineChanges);
printSection('Notes', state.notes);
printSection('Next steps', state.nextSteps);
printSection('Action required', state.failures);

if (state.failures.length > 0) {
  process.exit(1);
}
