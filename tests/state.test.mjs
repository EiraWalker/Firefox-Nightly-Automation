import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { OwnershipStore, ownsService } from '../src/state.mjs';

test('concurrent agents cannot both own the native approval operation', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'firefox-nightly-automation-test-'));
  try {
    const first = new OwnershipStore(directory);
    const second = new OwnershipStore(directory);
    const unlock = await first.lock();
    await assert.rejects(second.lock(), { message: 'F_OPERATION_BUSY' });
    await unlock();
    const release = await second.lock();
    await release();
    await first.write({ test: 1 });
    assert.deepEqual(await second.read(), { test: 1 });
    await first.clear();
    assert.equal(await second.read(), null);
  } finally {
    const resolved = path.resolve(directory);
    assert.equal(path.dirname(resolved), path.resolve(os.tmpdir()));
    assert(path.basename(resolved).startsWith('firefox-nightly-automation-test-'));
    await rm(resolved, { recursive: true });
  }
});
test('ownership is bound to browser lifetime and listener generation', () => {
  const browser = { processId: 42, created: 'birth-1', executablePath: 'C:\\Nightly\\firefox.exe' };
  const record = { phase: 'running', browser, port: 9222, endpointCreated: ['listener-1'] };
  const status = { browser, port: 9222, endpoint: { created: ['listener-1'] } };
  assert.equal(ownsService(record, status), true);
  assert.equal(ownsService(record, { ...status, browser: { ...browser, created: 'birth-2' } }), false);
  assert.equal(ownsService(record, { ...status, endpoint: { created: ['listener-2'] } }), false);
  assert.equal(ownsService({ ...record, phase: 'starting' }, status), false);
});
