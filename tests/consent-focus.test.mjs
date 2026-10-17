import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Exercise the actual policy compiled by the native adapter, with no window actions.
const result = spawnSync('pwsh.exe', ['-NoProfile', '-NonInteractive', '-File', fileURLToPath(new URL('./consent-focus-fixture.ps1', import.meta.url))], { encoding: 'utf8', windowsHide: true });
assert.equal(result.status, 0, result.stderr);
const checks = JSON.parse(result.stdout.trim());
for (const check of checks) test(check.name, () => assert.equal(check.actual, check.expected));

test('the removed activation flag is rejected before initializing any native worker', () => {
  const result = spawnSync(process.execPath, [fileURLToPath(new URL('../cli.mjs', import.meta.url)), 'status', '--allow-window-activation'], { encoding: 'utf8', windowsHide: true });
  assert.equal(result.status, 1);
  const response = JSON.parse(result.stdout.trim());
  assert.equal(response.error, 'F_INVALID_ARGUMENT');
  assert.equal(response.nativeTrace, undefined);
});
