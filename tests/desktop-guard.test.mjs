import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const result = spawnSync('pwsh.exe', ['-NoProfile', '-NonInteractive', '-File', fileURLToPath(new URL('./desktop-guard-fixture.ps1', import.meta.url))], { encoding: 'utf8', windowsHide: true });
assert.equal(result.status, 0, result.stderr);
for (const check of JSON.parse(result.stdout.trim())) {
  test(check.name, () => assert.equal(check.actual, check.expected));
}
