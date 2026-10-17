import test from 'node:test';
import assert from 'node:assert/strict';
import { installPermanentAddon } from '../src/addons.mjs';

const artifact = { path: 'E:\\test addons\\example.xpi', id: 'example@local.test', version: '2.0', sha256: 'test-hash' };
const permanent = { id: artifact.id, name: 'Example', version: artifact.version, isActive: true, temporarilyInstalled: false };
function fixture({ before = [], after = [permanent], replyId = artifact.id, failure, inventoryFailure = false } = {}) {
  const calls = [];
  let installed = false;
  const browser = { connection: { async send(method, params) {
    calls.push({ method, params });
    if (method === 'webExtension.moz:listExtensions') {
      if (inventoryFailure) throw new Error('private inventory text');
      return { result: { extensions: installed ? after : before } };
    }
    if (method === 'webExtension.install') {
      if (failure) throw new Error(failure);
      installed = true;
      return { result: { extension: replyId } };
    }
    throw new Error('unexpected command');
  } } };
  return { browser, calls };
}
test('installation always sends a permanent archive request and confirms active non-temporary state', async () => {
  const f = fixture();
  const result = await installPermanentAddon(f.browser, artifact, 0);
  assert.equal(result.permanent, true);
  assert.deepEqual(result.addon, permanent);
  assert.deepEqual(f.calls[1], { method: 'webExtension.install', params: { extensionData: { type: 'archivePath', path: artifact.path }, 'moz:permanent': true } });
});
test('a browser that activates the permanent replacement needs no restart or uninstall', async () => {
  const previous = { ...permanent, version: '1.0', temporarilyInstalled: true };
  const f = fixture({ before: [previous] });
  const result = await installPermanentAddon(f.browser, artifact, 0);
  assert.deepEqual(result.previous, previous);
  assert.deepEqual(f.calls.map(call => call.method), ['webExtension.moz:listExtensions', 'webExtension.install', 'webExtension.moz:listExtensions']);
});

test('a successful archive install shadowed by a temporary copy reports restart-required without clearing storage', async () => {
  const temporary = { ...permanent, version: '1.0', isActive: false, temporarilyInstalled: true };
  const f = fixture({ before: [temporary], after: [temporary] });
  const stages = [];
  const result = await installPermanentAddon(f.browser, artifact, 0, stage => stages.push(stage));
  assert.equal(result.status, 'restart-required');
  assert.equal(result.permanent, true);
  assert.deepEqual(result.visibleAddon, temporary);
  assert.equal(result.addon, undefined);
  assert.deepEqual(stages, ['addon-archive-installed']);
  assert.deepEqual(f.calls.map(call => call.method), ['webExtension.moz:listExtensions', 'webExtension.install', 'webExtension.moz:listExtensions']);
});
test('same-version installs are not silently skipped because rebuilt code may have changed', async () => {
  const f = fixture({ before: [permanent] });
  await installPermanentAddon(f.browser, artifact, 0);
  assert.equal(f.calls.filter(call => call.method === 'webExtension.install').length, 1);
});

test('a disabled same-version copy is replaced after Firefox first re-enables it', async () => {
  const f = fixture({ before: [{ ...permanent, isActive: false }] });
  const result = await installPermanentAddon(f.browser, artifact, 0);
  assert.equal(result.status, 'active');
  assert.equal(f.calls.filter(call => call.method === 'webExtension.install').length, 2);
});
test('signature failures are coded and do not fall back to temporary installation', async () => {
  const f = fixture({ failure: 'Could not verify signature: private/path.xpi' });
  await assert.rejects(installPermanentAddon(f.browser, artifact, 0), { message: 'F_ADDON_SIGNATURE_REQUIRED' });
  assert.equal(f.calls.filter(call => call.method === 'webExtension.install').length, 1);
  assert(f.calls.every(call => call.params['moz:permanent'] !== false));
});
test('a mismatched returned extension ID never produces an installation receipt', async () => {
  const f = fixture({ replyId: 'other@example' });
  await assert.rejects(installPermanentAddon(f.browser, artifact, 0), { message: 'F_ADDON_ID_MISMATCH' });
});
test('temporary and disabled results cannot masquerade as successful permanent installs', async () => {
  const temporary = fixture({ after: [{ ...permanent, temporarilyInstalled: true }] });
  await assert.rejects(installPermanentAddon(temporary.browser, artifact, 0), { message: 'F_TEMPORARY_ADDON_CONFLICT' });
  const disabled = fixture({ after: [{ ...permanent, isActive: false }] });
  await assert.rejects(installPermanentAddon(disabled.browser, artifact, 0), { message: 'F_ADDON_INSTALL_NOT_CONFIRMED' });
});
test('inventory failures stop before mutation and provider errors are not exposed', async () => {
  const f = fixture({ inventoryFailure: true });
  await assert.rejects(installPermanentAddon(f.browser, artifact, 0), { message: 'F_ADDON_INVENTORY_UNAVAILABLE' });
  assert.equal(f.calls.length, 1);
  const failed = fixture({ failure: 'private data with arbitrary server details' });
  await assert.rejects(installPermanentAddon(failed.browser, artifact, 0), { message: 'F_ADDON_INSTALL_FAILED' });
});
