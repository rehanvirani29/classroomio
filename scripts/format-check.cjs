const { execSync, spawnSync } = require('node:child_process');
const fs = require('node:fs');

const changed = execSync('git diff --cached --name-only --diff-filter=d', { encoding: 'utf8' })
  .trim()
  .split('\n')
  .filter((f) => f && fs.existsSync(f) && !fs.lstatSync(f).isSymbolicLink());

if (changed.length === 0) process.exit(0);

// Batch files to avoid Windows command-line length limits (~32767 chars)
const BATCH_SIZE = 20;
for (let i = 0; i < changed.length; i += BATCH_SIZE) {
  const batch = changed.slice(i, i + BATCH_SIZE);
  const result = spawnSync('pnpm', ['exec', 'prettier', '--check', '--ignore-unknown', ...batch], {
    stdio: 'inherit',
    shell: process.platform === 'win32'
  });

  if ((result.status ?? 0) !== 0) process.exit(result.status ?? 1);
}

process.exit(0);
