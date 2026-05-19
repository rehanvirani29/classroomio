const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const repoRoot = path.resolve(__dirname, '..');
const args = new Set(process.argv.slice(2));
const doctorMode = args.has('--doctor');
const strictMode = doctorMode || args.has('--strict');
const skipInstall = doctorMode || args.has('--skip-install');
const skipInfra = doctorMode || args.has('--skip-infra');
const withMinio = args.has('--with-minio');

const envSpecs = [
  {
    filePath: path.join(repoRoot, '.env'),
    examplePath: path.join(repoRoot, '.env.example'),
    defaults: {
      POSTGRES_DB: 'classroomio',
      POSTGRES_USER: 'postgres',
      POSTGRES_PASSWORD: 'postgres',
      PUBLIC_SERVER_URL: 'http://localhost:3081',
      TRUSTED_ORIGINS: 'http://localhost:3082,http://localhost:5173',
      BETTER_AUTH_SECRET: 'local-dev-only-secret-change-this',
      AUTH_BEARER_TOKEN: 'local-dev-api-key',
      PRIVATE_SERVER_KEY: 'local-dev-api-key',
      PUBLIC_IS_SELFHOSTED: 'true',
      PRIVATE_SERVER_URL: 'http://api:3081',
      DASHBOARD_ORIGIN: 'http://localhost:3082',
      MINIO_ROOT_USER: 'minioadmin',
      MINIO_ROOT_PASSWORD: 'minioadmin',
      OBJECT_STORAGE_ENDPOINT: 'http://minio:9000',
      OBJECT_STORAGE_PUBLIC_ENDPOINT: 'http://localhost:9000',
      OBJECT_STORAGE_ACCESS_KEY_ID: 'minioadmin',
      OBJECT_STORAGE_SECRET_ACCESS_KEY: 'minioadmin',
      OBJECT_STORAGE_FORCE_PATH_STYLE: 'true',
      OBJECT_STORAGE_MEDIA_PUBLIC_BASE_URL: 'http://localhost:9000/media',
      PRIVATE_APP_HOST: 'localhost',
      PRIVATE_APP_SUBDOMAINS: 'app'
    }
  },
  {
    filePath: path.join(repoRoot, 'apps', 'api', '.env'),
    examplePath: path.join(repoRoot, 'apps', 'api', '.env.example'),
    defaults: {
      DATABASE_URL: 'postgresql://postgres:postgres@localhost:5432/classroomio',
      REDIS_URL: 'redis://localhost:6379',
      PUBLIC_SERVER_URL: 'http://localhost:3002',
      TRUSTED_ORIGINS: 'http://localhost:5173,http://127.0.0.1:5173',
      BETTER_AUTH_SECRET: 'local-dev-only-secret-change-this',
      AUTH_BEARER_TOKEN: 'local-dev-api-key',
      PRIVATE_SERVER_KEY: 'local-dev-api-key',
      MINIO_ROOT_USER: 'minioadmin',
      MINIO_ROOT_PASSWORD: 'minioadmin',
      OBJECT_STORAGE_ENDPOINT: 'http://localhost:9000',
      OBJECT_STORAGE_PUBLIC_ENDPOINT: 'http://localhost:9000',
      OBJECT_STORAGE_ACCESS_KEY_ID: 'minioadmin',
      OBJECT_STORAGE_SECRET_ACCESS_KEY: 'minioadmin',
      OBJECT_STORAGE_FORCE_PATH_STYLE: 'true',
      OBJECT_STORAGE_MEDIA_PUBLIC_BASE_URL: 'http://localhost:9000/media',
      SMTP_HOST: '',
      SMTP_PORT: '',
      SMTP_USER: '',
      SMTP_SENDER: '',
      SMTP_PASSWORD: ''
    }
  },
  {
    filePath: path.join(repoRoot, 'apps', 'dashboard', '.env'),
    examplePath: path.join(repoRoot, 'apps', 'dashboard', '.env.example'),
    defaults: {
      PUBLIC_IS_SELFHOSTED: 'true',
      PUBLIC_SERVER_URL: 'http://localhost:3002',
      PRIVATE_SERVER_URL: 'http://localhost:3002',
      PRIVATE_SERVER_KEY: 'local-dev-api-key',
      AUTH_BEARER_TOKEN: 'local-dev-api-key',
      PRIVATE_APP_HOST: 'localhost',
      PRIVATE_APP_SUBDOMAINS: 'app'
    }
  }
];

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function normalizeEnvValue(rawValue) {
  if (rawValue === undefined) {
    return '';
  }

  let value = rawValue.trim();
  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
    value = value.slice(1, -1);
  }

  return value.trim();
}

function shouldReplaceValue(rawValue) {
  const value = normalizeEnvValue(rawValue);

  if (!value) {
    return true;
  }

  if (value === 'replace-with-a-long-random-secret') {
    return true;
  }

  return /^(replace-with-|changeme$|replace-me$)/.test(value) || value.includes('change-this');
}

function ensureDirectory(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function ensureFile(spec) {
  if (fs.existsSync(spec.filePath)) {
    return false;
  }

  ensureDirectory(spec.filePath);
  if (fs.existsSync(spec.examplePath)) {
    fs.copyFileSync(spec.examplePath, spec.filePath);
  } else {
    fs.writeFileSync(spec.filePath, '', 'utf8');
  }

  return true;
}

function upsertEnvDefaults(spec, forceDefaults) {
  const text = fs.existsSync(spec.filePath) ? fs.readFileSync(spec.filePath, 'utf8') : '';
  const lines = text ? text.split(/\r?\n/) : [];
  const nextLines = lines.length > 0 ? [...lines] : [];
  let changed = false;

  for (const [key, value] of Object.entries(spec.defaults)) {
    const matcher = new RegExp(`^${escapeRegExp(key)}=`);
    const index = nextLines.findIndex((line) => matcher.test(line));

    if (index === -1) {
      nextLines.push(`${key}=${value}`);
      changed = true;
      continue;
    }

    const currentValue = nextLines[index].slice(nextLines[index].indexOf('=') + 1);
    if (forceDefaults || shouldReplaceValue(currentValue)) {
      const nextLine = `${key}=${value}`;
      if (nextLines[index] !== nextLine) {
        nextLines[index] = nextLine;
        changed = true;
      }
    }
  }

  if (changed) {
    fs.writeFileSync(spec.filePath, `${nextLines.join('\n').replace(/\n*$/, '')}\n`, 'utf8');
  }

  return changed;
}

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

  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

function isDockerDaemonReady() {
  if (!commandExists('docker')) {
    return false;
  }

  const result = spawnSync('docker', ['info'], { stdio: 'ignore' });
  return result.status === 0;
}

function readRequiredNodeVersion() {
  const versionPath = path.join(repoRoot, '.nvmrc');
  if (!fs.existsSync(versionPath)) {
    return null;
  }

  return fs.readFileSync(versionPath, 'utf8').trim();
}

function printChecklist(title, items) {
  if (items.length === 0) {
    return;
  }

  console.log(`\n${title}`);
  for (const item of items) {
    console.log(`- ${item}`);
  }
}

function buildInstallHints() {
  const hints = [];
  const onWindows = process.platform === 'win32';
  const hasWinget = commandExists('winget');

  if (onWindows && hasWinget) {
    hints.push('Install NVM for Windows: winget install --id CoreyButler.NVMforWindows -e');
    hints.push('Install Docker Desktop: winget install --id Docker.DockerDesktop -e');
  }

  return hints;
}

const requiredNodeVersion = readRequiredNodeVersion();
const currentNodeVersion = process.version;
const issues = [];
const changes = [];
const notes = [];
const installHints = buildInstallHints();

if (requiredNodeVersion && currentNodeVersion !== requiredNodeVersion) {
  issues.push(`Node ${requiredNodeVersion} is recommended, current version is ${currentNodeVersion}.`);
}

if (!commandExists('corepack')) {
  issues.push('corepack is not available on PATH, so pnpm cannot be bootstrapped reliably.');
}

if (doctorMode) {
  if (!commandExists('docker')) {
    issues.push('Docker is not installed or not on PATH.');
  } else if (!isDockerDaemonReady()) {
    issues.push('Docker is installed but the daemon is not responding. Start Docker Desktop and rerun setup.');
  }
}

if (!doctorMode) {
  for (const spec of envSpecs) {
    const created = ensureFile(spec);
    const updated = upsertEnvDefaults(spec, created);

    if (created) {
      changes.push(`created ${path.relative(repoRoot, spec.filePath)}`);
    }

    if (updated) {
      changes.push(`updated defaults in ${path.relative(repoRoot, spec.filePath)}`);
    }
  }

  const requiredEnvKeys = [
    {
      file: path.join(repoRoot, 'apps', 'api', '.env'),
      keys: ['DATABASE_URL', 'REDIS_URL', 'AUTH_BEARER_TOKEN', 'BETTER_AUTH_SECRET']
    },
    {
      file: path.join(repoRoot, 'apps', 'dashboard', '.env'),
      keys: ['PUBLIC_SERVER_URL', 'PRIVATE_SERVER_KEY', 'PUBLIC_IS_SELFHOSTED']
    }
  ];
  for (const { file, keys } of requiredEnvKeys) {
    const text = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
    const rel = path.relative(repoRoot, file);
    for (const key of keys) {
      const match = text.match(new RegExp(`^${key}=(.*)`, 'm'));
      if (!match || shouldReplaceValue(match[1])) {
        issues.push(`${rel}: ${key} is missing or still a placeholder — set a real value before starting the servers.`);
      }
    }
  }

  const aiKeyNames = ['OPENAI_API_KEY', 'GOOGLE_API_KEY', 'ANTHROPIC_API_KEY', 'MOONSHOT_API_KEY'];
  const apiEnvPath = path.join(repoRoot, 'apps', 'api', '.env');
  const apiEnvText = fs.existsSync(apiEnvPath) ? fs.readFileSync(apiEnvPath, 'utf8') : '';
  const hasAiKey = aiKeyNames.some((key) => {
    const match = apiEnvText.match(new RegExp(`^${key}=(.+)`, 'm'));
    return match && !shouldReplaceValue(match[1]);
  });
  if (!hasAiKey) {
    notes.push(
      'AI features are disabled. Set at least one of OPENAI_API_KEY, GOOGLE_API_KEY, or ANTHROPIC_API_KEY in apps/api/.env to enable them.'
    );
  }
}

if (!skipInstall && commandExists('corepack')) {
  console.log('\nInstalling workspace dependencies...');
  runCommand('corepack', ['pnpm', 'install']);
} else if (!skipInstall) {
  notes.push('Skipped dependency install because corepack is unavailable.');
}

if (!skipInfra) {
  if (!commandExists('docker')) {
    issues.push('Docker is not installed or not on PATH.');
  } else if (!isDockerDaemonReady()) {
    issues.push('Docker is installed but the daemon is not responding. Start Docker Desktop and rerun setup.');
  } else {
    const composeArgs = ['compose', '-f', 'docker/docker-compose.yaml'];
    if (withMinio) {
      composeArgs.push('--profile', 'minio');
    }
    composeArgs.push('up', '-d', 'postgres', 'redis');
    if (withMinio) {
      composeArgs.push('minio', 'minio-init');
    }

    console.log('\nStarting local infrastructure...');
    runCommand('docker', composeArgs);
  }
}

if (doctorMode) {
  console.log('ClassroomIO dev environment doctor');
  console.log(`- Required Node: ${requiredNodeVersion || 'not specified'}`);
  console.log(`- Current Node: ${currentNodeVersion}`);
  console.log(`- corepack available: ${commandExists('corepack') ? 'yes' : 'no'}`);
  console.log(`- docker available: ${commandExists('docker') ? 'yes' : 'no'}`);
  console.log(`- docker daemon ready: ${isDockerDaemonReady() ? 'yes' : 'no'}`);
} else {
  console.log(
    issues.length === 0 ? '\nClassroomIO dev setup complete.' : '\nClassroomIO dev setup requires follow-up.'
  );
}

printChecklist('Changes applied', changes);
printChecklist('Notes', notes);
printChecklist('Action required', issues);
printChecklist('Install hints', installHints);

if (!doctorMode && issues.length === 0) {
  console.log('\nNext commands');
  console.log('- corepack pnpm api:dev');
  console.log('- corepack pnpm dashboard:dev');
  if (withMinio) {
    console.log('- MinIO console: http://localhost:9001');
  }
} else if (!doctorMode) {
  console.log('\nResolve the action items above, then rerun setup.');
  if (strictMode) {
    console.log('This non-zero exit is expected while required prerequisites are still missing.');
  } else {
    console.log('This command completed with warnings so onboarding can continue without a hard failure.');
  }
}

if (issues.length > 0 && strictMode) {
  process.exit(1);
}
