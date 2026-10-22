#!/usr/bin/env node
// Configure git to use .githooks/ as the hooks directory.
// Must never fail the install (CI / no-git / non-repo environments).

import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { access, constants } from 'node:fs/promises';
import { resolve } from 'node:path';

const execFileAsync = promisify(execFile);

async function main() {
  const repoRoot = resolve(import.meta.dirname, '..');

  // No .git (installed as dependency / tarball) -> nothing to configure.
  try {
    await access(resolve(repoRoot, '.git'), constants.F_OK);
  } catch {
    return;
  }

  // Respect an existing core.hooksPath: don't clobber a contributor's own
  // hooks setup (Husky, a custom dir, etc.). Only set it when unset or already
  // pointing at .githooks.
  let existing = '';
  try {
    const { stdout } = await execFileAsync(
      'git',
      ['config', '--get', 'core.hooksPath'],
      { cwd: repoRoot },
    );
    existing = stdout.trim();
  } catch {
    // Unset (exit code 1) or git missing: treat as no existing value.
  }

  if (existing && existing !== '.githooks') {
    console.warn(
      `setup-hooks: core.hooksPath is already set to '${existing}'; ` +
        'leaving it unchanged. To enable branch-name checks, run: ' +
        'git config core.hooksPath .githooks',
    );
    return;
  }

  try {
    await execFileAsync('git', ['config', 'core.hooksPath', '.githooks'], {
      cwd: repoRoot,
    });
  } catch {
    // git missing or config failed: never break the install.
  }
}

main().catch(() => {});
