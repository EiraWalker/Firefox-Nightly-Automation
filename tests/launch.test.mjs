import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const launcher = fileURLToPath(new URL('../scripts/start-nightly.ps1', import.meta.url));
const powershell = 'pwsh.exe';
const psQuote = value => `'${value.replaceAll("'", "''")}'`;

test('Nightly launcher grants system access only to its child and preserves quoted arguments', { skip: process.platform !== 'win32' }, async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'nightly-launch-'));
  try {
    const probe = path.join(directory, 'probe with spaces.mjs');
    const receipt = path.join(directory, 'child environment.json');
    await writeFile(probe, "import fs from 'node:fs'; fs.writeFileSync(process.argv[2], JSON.stringify({ access: process.env.MOZ_REMOTE_ALLOW_SYSTEM_ACCESS, args: process.argv.slice(3) }));");
    const commandLine = `"${probe}" "${receipt}" "argument with spaces"`;
    const command = `& ${psQuote(launcher)} -ExecutablePath ${psQuote(process.execPath)} -Arguments ${psQuote(commandLine)} -PassThru; Write-Output ('PARENT_ACCESS=' + $env:MOZ_REMOTE_ALLOW_SYSTEM_ACCESS)`;
    const result = await execFileAsync(powershell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', command], {
      windowsHide: true, timeout: 15000, env: { ...process.env, MOZ_REMOTE_ALLOW_SYSTEM_ACCESS: '0' },
    });
    assert.match(result.stdout, /PARENT_ACCESS=0/);
    assert.equal(JSON.parse(result.stdout.split(/\r?\n/).find(line => line.startsWith('{'))).requestedSystemAccess, true);
    let saved;
    for (let attempt = 0; attempt < 100; attempt++) {
      try { saved = JSON.parse(await readFile(receipt, 'utf8')); break; }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert.deepEqual(saved, { access: '1', args: ['argument with spaces'] });
  } finally {
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(tmpdir()));
    assert(path.basename(directory).startsWith('nightly-launch-'));
    await rm(directory, { recursive: true, force: true });
  }
});

test('Nightly launcher fails when the executable is missing', { skip: process.platform !== 'win32' }, async () => {
  await assert.rejects(execFileAsync(powershell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', launcher, '-ExecutablePath', path.join(tmpdir(), 'missing-nightly-executable.exe')], {
    windowsHide: true, timeout: 15000,
  }), error => error.code === 1 && /missing-nightly-executable/.test(error.stderr));
});
