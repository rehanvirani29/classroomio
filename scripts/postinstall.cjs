const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

if (!fs.existsSync(path.join(process.cwd(), '.git'))) {
  process.exit(0);
}

const executable = path.join(
  process.cwd(),
  'node_modules',
  '.bin',
  process.platform === 'win32' ? 'lefthook.cmd' : 'lefthook'
);

const result =
  process.platform === 'win32'
    ? spawnSync(`"${executable}" install`, {
        cwd: process.cwd(),
        stdio: 'inherit',
        shell: true
      })
    : spawnSync(executable, ['install'], {
        cwd: process.cwd(),
        stdio: 'inherit',
        shell: false
      });

if (result.error) {
  console.warn('[postinstall] lefthook install skipped:', result.error.message);
  process.exit(0);
}

process.exit(result.status ?? 0);
