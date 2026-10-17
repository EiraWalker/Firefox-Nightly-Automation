import test from 'node:test';
import assert from 'node:assert/strict';
import { NightlyAutomation } from '../src/automation.mjs';
import { ownsService } from '../src/state.mjs';

function fixture({ running = false, busy = false, minimized = false } = {}) {
  const events = [];
  let record = null;
  let status = {
    browser: { processId: 42, created: 'browser-1', executablePath: 'C:\\Nightly\\firefox.exe' },
    port: 9222,
    endpoint: running ? { listening: true, verified: true, created: ['service-1'] } : { listening: false, verified: false },
    toolbarAvailable: true, toolbarRunning: running,
  };
  let active = false;
  const native = {
    async request(op, payload) {
      events.push(`${op}${op === 'power' ? `:${payload.enabled}` : ''}`);
      if (op === 'status') return structuredClone(status);
      if (op === 'assert') return { foregroundStable: true, clipboardStable: true, windowsStable: true };
      if (op === 'power') {
        if (minimized) throw new Error('F_BACKGROUND_CONTROL_UNAVAILABLE');
        if (!payload.enabled && !payload.resetExisting) assert.equal(active, true, 'ordinary stop must hold its own exclusive session');
        status.toolbarRunning = payload.enabled;
        status.endpoint = payload.enabled ? { listening: true, verified: true, created: ['service-2'] } : { listening: false, verified: false };
      }
    },
  };
  const store = {
    async read() { return structuredClone(record); },
    async write(value) { record = structuredClone(value); },
    async clear() { record = null; },
  };
  const connect = async () => {
    events.push('connect');
    if (busy) throw new Error('F_SESSION_BUSY');
    active = true;
    return { browser: { marker: 7 }, consent: { seen: true, invoked: true, closed: true }, async release() { events.push('release'); active = false; } };
  };
  return {
    automation: new NightlyAutomation({ native, store, connect }), native, store, events,
    get record() { return record; }, get status() { return status; },
  };
}

test('start verifies a connection and retains the newly enabled service for a later stop', async () => {
  const f = fixture();
  const result = await f.automation.start();
  assert.equal(result.startedHere, true);
  assert.equal(result.handshake, true);
  assert.equal(f.status.endpoint.listening, true);
  assert.equal(ownsService(f.record, f.status), true);
  assert.equal(f.events.at(-1), 'release');
});
test('run closes only the service it enabled, while its own session is still held', async () => {
  const f = fixture();
  const result = await f.automation.run(async browser => { assert.equal(browser.marker, 7); f.events.push('task'); return 19; });
  assert.equal(result.task, 19);
  assert.equal(result.stoppedHere, true);
  assert.equal(f.record, null);
  assert.equal(f.status.endpoint.listening, false);
  assert(f.events.indexOf('task') < f.events.indexOf('power:false'));
  assert(f.events.indexOf('power:false') < f.events.indexOf('release'));
});
test('run preserves pre-existing remote control', async () => {
  const f = fixture({ running: true });
  const result = await f.automation.run(async () => 'done');
  assert.equal(result.startedHere, false);
  assert.equal(result.stoppedHere, false);
  assert.equal(f.status.endpoint.listening, true);
  assert(!f.events.some(item => item.startsWith('power')));
});
test('stop does not connect or change an unowned service', async () => {
  const f = fixture({ running: true });
  const result = await f.automation.stop();
  assert.equal(result.reason, 'not-owned');
  assert(!f.events.includes('connect'));
  assert.equal(f.status.endpoint.listening, true);
});
test('a service opened with start can be stopped after its verification connection ends', async () => {
  const f = fixture();
  await f.automation.start();
  const result = await f.automation.stop();
  assert.equal(result.stopped, true);
  assert.equal(f.record, null);
});
test('a manual restart of the same Firefox process invalidates old service ownership', async () => {
  const f = fixture();
  await f.automation.start();
  f.status.endpoint.created = ['user-service-3'];
  const result = await f.automation.stop();
  assert.equal(result.reason, 'not-owned');
  assert.equal(f.status.endpoint.listening, true);
});
test('a task failure still cleans up the service without echoing its private error', async () => {
  const f = fixture();
  await assert.rejects(f.automation.run(async () => { throw new Error('private task text'); }), { message: 'F_TASK_FAILED' });
  assert.equal(f.status.endpoint.listening, false);
  assert.equal(f.record, null);
  assert.equal(f.events.at(-1), 'release');
});
test('cleanup failure disconnects its own client but retains ownership for diagnosis', async () => {
  const f = fixture();
  const request = f.native.request;
  f.native.request = async (op, payload) => { if (op === 'power' && !payload.enabled) throw new Error('F_BACKGROUND_PANEL_UNAVAILABLE'); return request(op, payload); };
  await assert.rejects(f.automation.run(async () => true), { message: 'F_BACKGROUND_PANEL_UNAVAILABLE' });
  assert.equal(f.status.endpoint.listening, true);
  assert.equal(f.record.phase, 'running');
  assert.equal(f.events.at(-1), 'release');
});
test('occupied sessions are reported without running tasks or stopping existing control', async () => {
  const f = fixture({ running: true, busy: true });
  let taskRan = false;
  await assert.rejects(f.automation.run(async () => { taskRan = true; }), { message: 'F_SESSION_BUSY' });
  assert.equal(taskRan, false);
  assert.equal(f.status.endpoint.listening, true);
  assert(!f.events.includes('power:false'));
});
test('an endpoint owned by another process is never used', async () => {
  const f = fixture({ running: true });
  f.status.endpoint.verified = false;
  await assert.rejects(f.automation.start(), { message: 'F_ENDPOINT_UNSAFE' });
  assert(!f.events.includes('connect'));
});
test('offscreen controls fail without restoring the browser, acquiring a session, or keeping false ownership', async () => {
  const f = fixture({ minimized: true });
  await assert.rejects(f.automation.start(), { message: 'F_BACKGROUND_CONTROL_UNAVAILABLE' });
  assert.equal(f.status.endpoint.listening, false);
  assert.equal(f.record, null);
  assert(!f.events.includes('connect'));
});
test('inconsistent native indicator does not trigger a blind toggle', async () => {
  const f = fixture();
  f.status.toolbarRunning = true;
  await assert.rejects(f.automation.start(), { message: 'F_REMOTE_CONTROL_INCONSISTENT' });
  assert(!f.events.some(event => event.startsWith('power')));
});
test('a desktop change prevents cleanup UI actions and still releases the owned connection', async () => {
  const f = fixture({ running: true });
  const request = f.native.request;
  f.native.request = async (op, payload) => { if (op === 'assert') throw new Error('F_DESKTOP_CHANGED'); return request(op, payload); };
  await assert.rejects(f.automation.run(async () => true), { message: 'F_DESKTOP_CHANGED' });
  assert.equal(f.events.at(-1), 'release');
});

test('restart requires explicit reset and cannot change the ordinary stop policy', async () => {
  const f = fixture({ running: true, busy: true });
  await assert.rejects(f.automation.restart(), { message: 'F_RESET_AUTHORIZATION_REQUIRED' });
  assert.deepEqual(f.events, []);
  assert.equal((await f.automation.stop()).reason, 'not-owned');
});
test('explicit restart resets an occupied pre-existing service before connecting to the new one', async () => {
  const f = fixture({ running: true });
  const result = await f.automation.restart({ resetExisting: true });
  assert.equal(result.serviceRestarted, true);
  assert.equal(result.handshake, true);
  assert.equal(result.owned, true);
  assert(f.events.indexOf('power:false') < f.events.indexOf('power:true'));
  assert(f.events.indexOf('power:true') < f.events.indexOf('connect'));
  assert.equal(ownsService(f.record, f.status), true);
});
test('restart preserves browser state when native controls are unavailable in the background', async () => {
  const f = fixture({ running: true, minimized: true });
  await assert.rejects(f.automation.restart({ resetExisting: true }), { message: 'F_BACKGROUND_CONTROL_UNAVAILABLE' });
  assert.equal(f.status.endpoint.listening, true);
  assert.equal(f.record, null);
  assert(!f.events.includes('power:true'));
  assert(!f.events.includes('connect'));
});
test('explicit reset cannot stop a port belonging to another process', async () => {
  const f = fixture({ running: true });
  f.status.endpoint.verified = false;
  await assert.rejects(f.automation.restart({ resetExisting: true }), { message: 'F_ENDPOINT_UNSAFE' });
  assert(!f.events.some(event => event.startsWith('power')));
});

test('protocol reset clears occupancy before handshake without clicking the native panel', async () => {
  const f = fixture({ running: true, minimized: true });
  let reset = false;
  f.automation.resetSession = async () => { f.events.push('reset-session'); reset = true; };
  const result = await f.automation.restart({ resetExisting: true });
  assert.equal(reset, true);
  assert.equal(result.sessionReset, true);
  assert.equal(result.serviceRestarted, false);
  assert.equal(result.handshake, true);
  assert(f.events.indexOf('reset-session') < f.events.indexOf('connect'));
  assert(!f.events.some(event => event.startsWith('power')));
});
test('failed protocol reset prevents a new session and leaves the native service untouched', async () => {
  const f = fixture({ running: true });
  f.automation.resetSession = async () => { throw new Error('F_SESSION_RESET_FAILED'); };
  await assert.rejects(f.automation.restart({ resetExisting: true }), { message: 'F_SESSION_RESET_FAILED' });
  assert(!f.events.includes('connect'));
  assert(!f.events.some(event => event.startsWith('power')));
});

test('explicit service restart bypasses protocol reset and records confirmed off/on stages', async () => {
  const f = fixture({ running: true });
  f.automation.resetSession = async () => { throw new Error('protocol reset must not run'); };
  const result = await f.automation.restart({ resetExisting: true, restartService: true });
  assert.equal(result.mode, 'service-restart');
  assert.equal(result.serviceRestarted, true);
  assert.equal(result.owned, true);
  assert.deepEqual(f.automation.completedStages, ['service-stopped', 'service-started']);
  assert(f.events.indexOf('closeResetConsent') < f.events.indexOf('power:false'));
  assert(f.events.indexOf('power:false') < f.events.indexOf('power:true'));
});

test('service restart reports confirmed power stages if the next handshake fails', async () => {
  const f = fixture({ running: true, busy: true });
  await assert.rejects(f.automation.restart({ resetExisting: true, restartService: true }), { message: 'F_SESSION_BUSY' });
  assert.deepEqual(f.automation.completedStages, ['service-stopped', 'service-started']);
  assert.equal(f.status.endpoint.listening, true);
  assert.equal(ownsService(f.record, f.status), true);
});
test('reset-session can clear an occupied session without creating any new connection or native panel', async () => {
  const f = fixture({ running: true, busy: true, minimized: true });
  f.automation.resetSession = async () => ({ deleteSessionCompleted: true });
  const result = await f.automation.reset({ resetExisting: true });
  assert.equal(result.sessionReset, true);
  assert.equal(result.serviceRestarted, false);
  assert(!f.events.includes('connect'));
  assert(!f.events.some(event => event.startsWith('power')));
});
test('reset-session reports already clear and still requires explicit reset authorization', async () => {
  const f = fixture({ running: true });
  f.automation.resetSession = async () => ({ sessionAlreadyClear: true });
  await assert.rejects(f.automation.reset(), { message: 'F_RESET_AUTHORIZATION_REQUIRED' });
  assert.equal((await f.automation.reset({ resetExisting: true })).sessionAlreadyClear, true);
});

test('install uses the existing service and preserves its coded installation result through cleanup', async () => {
  const f = fixture({ running: true });
  const addon = { id: 'example@local', name: 'Example', version: '1.0', isActive: true, temporarilyInstalled: false };
  let installed = false;
  let released = false;
  f.automation.connect = async () => ({
    consent: { seen: true, invoked: true, closed: true },
    browser: { connection: { async send(method, params) {
      if (method === 'webExtension.install') { assert.equal(params['moz:permanent'], true); installed = true; return { result: { extension: addon.id } }; }
      return { result: { extensions: installed ? [addon] : [] } };
    } } },
    async release() { released = true; },
  });
  const result = await f.automation.install({ id: addon.id, version: addon.version, path: 'E:\\fixture.xpi', sha256: 'hash' });
  assert.equal(result.installation.permanent, true);
  assert.equal(result.task, undefined);
  assert.equal(result.handshake, true);
  assert.equal(released, true);
  assert.deepEqual(f.automation.completedStages, ['addon-archive-installed', 'addon-installed']);
  assert(!f.events.some(event => event.startsWith('power')));
});

test('installation failures retain their actionable code and still release the owned connection', async () => {
  const f = fixture({ running: true });
  let released = false;
  f.automation.connect = async () => ({
    browser: { connection: { async send(method) {
      if (method === 'webExtension.install') throw new Error('Signature verification failed, private details');
      return { result: { extensions: [] } };
    } } },
    async release() { released = true; },
  });
  await assert.rejects(f.automation.install({ id: 'example@local', version: '1.0', path: 'E:\\fixture.xpi' }), { message: 'F_ADDON_SIGNATURE_REQUIRED' });
  assert.equal(released, true);
  assert.deepEqual(f.automation.completedStages, []);
});
