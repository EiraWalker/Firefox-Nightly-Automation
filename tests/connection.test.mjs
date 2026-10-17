import test from 'node:test';
import assert from 'node:assert/strict';
import { connectApproved, openTransport } from '../src/connection.mjs';
import { WebSocketServer } from 'ws';

function fixture({ pollFailure, rejectConnection } = {}) {
  const events = [];
  const native = { async request(op) {
    events.push(op);
    if (op === 'pollConsent' && pollFailure) throw new Error(pollFailure);
    return op === 'pollConsent' ? { seen: true, invoked: true, closed: true } : {};
  } };
  const transport = { closed: false, async shutdown() { events.push('transport-close'); this.closed = true; } };
  const transportFactory = async () => transport;
  let connectOptions;
  const browser = { async version() { return 'firefox/160.0a1'; }, async disconnect() { events.push('disconnect'); } };
  const connect = async options => {
    connectOptions = options;
    await new Promise(resolve => setTimeout(resolve, 1));
    if (rejectConnection) throw new Error(rejectConnection);
    return browser;
  };
  return { native, transport, transportFactory, connect, browser, events, get connectOptions() { return connectOptions; } };
}
test('approval is armed before the single connection request and disarmed after handshake', async () => {
  const f = fixture();
  const session = await connectApproved(f.native, { port: 9222 }, 1000, f.connect, f.transportFactory);
  assert.equal(f.events[0], 'beginConsent');
  assert.equal(f.events.at(-1), 'endConsent');
  assert.equal(f.connectOptions.protocol, 'webDriverBiDi');
  assert.equal(f.connectOptions.defaultViewport, null);
  assert.equal(f.connectOptions.networkEnabled, false);
  assert.equal(f.connectOptions.capabilities.unhandledPromptBehavior, 'ignore');
  await session.release();
  assert.equal(f.transport.closed, true);
  assert.equal(f.events.at(-2), 'disconnect');
});
test('ambiguous consent terminates the pending transport without further approval attempts', async () => {
  const f = fixture({ pollFailure: 'F_CONSENT_AMBIGUOUS' });
  await assert.rejects(connectApproved(f.native, { port: 9222 }, 1000, f.connect, f.transportFactory), { message: 'F_CONSENT_AMBIGUOUS' });
  assert.equal(f.transport.closed, true);
  assert.equal(f.events.filter(event => event === 'pollConsent').length, 1);
  assert.equal(f.events.at(-1), 'endConsent');
});
test('an already visible consent dialog prevents opening a socket', async () => {
  let opened = false;
  const native = { async request() { throw new Error('F_CONSENT_ALREADY_PRESENT'); } };
  await assert.rejects(connectApproved(native, { port: 9222 }, 1000, () => {}, async () => { opened = true; }), { message: 'F_CONSENT_ALREADY_PRESENT' });
  assert.equal(opened, false);
});
test('busy-session errors are classified and never return service messages or URLs', async () => {
  const f = fixture({ rejectConnection: 'Maximum number of active sessions https://private.example/' });
  await assert.rejects(connectApproved(f.native, { port: 9222 }, 1000, f.connect, f.transportFactory), { message: 'F_SESSION_BUSY' });
  assert.equal(f.transport.closed, true);
});
test('connection timeout closes its socket and disables the temporary approval watcher', async () => {
  const f = fixture();
  await assert.rejects(connectApproved(f.native, { port: 9222 }, 30, () => new Promise(() => {}), f.transportFactory), { message: 'F_CONNECTION_TIMEOUT' });
  assert.equal(f.transport.closed, true);
  assert.equal(f.events.at(-1), 'endConsent');
});

test('a partial Puppeteer initialization ends its acknowledged session on the original socket', async () => {
  const server = new WebSocketServer({ host: '127.0.0.1', port: 0 });
  await new Promise(resolve => server.once('listening', resolve));
  const methods = [];
  server.on('connection', socket => socket.on('message', raw => {
    const packet = JSON.parse(raw.toString());
    methods.push(packet.method);
    socket.send(JSON.stringify({ type: 'success', id: packet.id, result: packet.method === 'session.new' ? { sessionId: 'owned-session' } : {} }));
  }));
  try {
    const transport = await openTransport(`ws://127.0.0.1:${server.address().port}`, 1000);
    const received = new Promise(resolve => { transport.onmessage = resolve; });
    transport.send(JSON.stringify({ id: 1, method: 'session.new', params: {} }));
    await received;
    await transport.shutdown();
    assert.deepEqual(methods, ['session.new', 'session.end']);
  } finally { await new Promise(resolve => server.close(resolve)); }
});
test('a rejected new session never causes an end command for someone else’s session', async () => {
  const server = new WebSocketServer({ host: '127.0.0.1', port: 0 });
  await new Promise(resolve => server.once('listening', resolve));
  const methods = [];
  server.on('connection', socket => socket.on('message', raw => {
    const packet = JSON.parse(raw.toString());
    methods.push(packet.method);
    socket.send(JSON.stringify({ type: 'error', id: packet.id, error: 'session not created', message: 'Maximum number of active sessions' }));
  }));
  try {
    const transport = await openTransport(`ws://127.0.0.1:${server.address().port}`, 1000);
    const received = new Promise(resolve => { transport.onmessage = resolve; });
    transport.send(JSON.stringify({ id: 1, method: 'session.new', params: {} }));
    await received;
    await transport.shutdown();
    assert.deepEqual(methods, ['session.new']);
  } finally { await new Promise(resolve => server.close(resolve)); }
});
