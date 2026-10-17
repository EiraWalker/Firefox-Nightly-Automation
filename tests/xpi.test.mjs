import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { inspectXpi } from '../src/xpi.mjs';

let directory;
before(async () => {
  directory = await mkdtemp(path.join(os.tmpdir(), 'nightly xpi-'));
  execFileSync('pwsh.exe', ['-NoProfile', '-File', fileURLToPath(new URL('./xpi-fixture.ps1', import.meta.url)), '-Directory', directory], { windowsHide: true });
});
after(async () => { await rm(directory, { recursive: true, force: true }); });
test('XPI metadata and hash come from the actual archive, including paths with spaces', async () => {
  const file = path.join(directory, 'valid.xpi');
  const result = await inspectXpi(file);
  assert.equal(result.id, 'example@local.test');
  assert.equal(result.version, '2.0');
  assert.equal(result.sha256, createHash('sha256').update(await readFile(file)).digest('hex'));
});
test('directories, ZIP-only arguments and missing files are rejected before browser connection', async () => {
  await assert.rejects(inspectXpi(directory), { message: 'F_XPI_REQUIRED' });
  await assert.rejects(inspectXpi(path.join(directory, 'valid.zip')), { message: 'F_XPI_REQUIRED' });
  await assert.rejects(inspectXpi(path.join(directory, 'missing.xpi')), { message: 'F_XPI_INVALID' });
});
test('malformed and duplicate manifests are rejected rather than selecting arbitrary metadata', async () => {
  await assert.rejects(inspectXpi(path.join(directory, 'duplicate.xpi')), { message: 'F_XPI_INVALID' });
  await assert.rejects(inspectXpi(path.join(directory, 'invalid-json.xpi')), { message: 'F_XPI_INVALID' });
  const invalid = path.join(directory, 'not-an-archive.xpi');
  await writeFile(invalid, 'not a zip');
  await assert.rejects(inspectXpi(invalid), { message: 'F_XPI_INVALID' });
});
test('unsigned permanent installation requires a declared fixed addon ID', async () => {
  await assert.rejects(inspectXpi(path.join(directory, 'missing-id.xpi')), { message: 'F_XPI_ID_REQUIRED' });
});
test('install requires an XPI and invalid artifacts never initialize a native worker', () => {
  for (const args of [['install'], ['install', '--xpi', path.join(directory, 'missing.xpi')]]) {
    const result = spawnSync(process.execPath, [fileURLToPath(new URL('../cli.mjs', import.meta.url)), ...args], { encoding: 'utf8', windowsHide: true });
    assert.equal(result.status, 1);
    const response = JSON.parse(result.stdout.trim());
    assert.equal(response.nativeTrace, undefined);
    assert.match(response.error, /^F_XPI_/);
  }
});
