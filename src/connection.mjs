import puppeteer from 'puppeteer-core';
import WebSocket from 'ws';

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

// Public Puppeteer ConnectionTransport interface; the WebDriver protocol stays upstream.
export async function openTransport(endpoint, timeoutMs, { bootstrapLogs = false } = {}) {
  const socket = new WebSocket(endpoint);
  socket.on('error', () => {});
  let timer;
  try {
    await new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new Error('F_CONNECTION_TIMEOUT')), timeoutMs);
      socket.once('open', resolve);
      socket.once('error', () => reject(new Error('F_CONNECTION_FAILED')));
    });
  } catch (error) { socket.terminate(); throw error; }
  finally { clearTimeout(timer); }
  let newSessionRequest;
  let ownSession = false;
  let endingRequest;
  let endResolver;
  const transport = {
    send(message) {
      const packet = JSON.parse(message);
      // Puppeteer's global bootstrap includes `log`, which replays every user
      // tab's console history. Scoped tasks need navigation/realm/input events,
      // not unrelated logs; keep explicit scoped subscriptions unchanged.
      const params = packet.params;
      if (!bootstrapLogs && packet.method === 'session.subscribe' &&
          Array.isArray(params?.events) && params.events.includes('browsingContext') &&
          params.events.includes('script') && params.events.includes('log') &&
          !('contexts' in params) && !('userContexts' in params)) {
        packet.params = { ...params, events: params.events.filter(event => event !== 'log') };
        message = JSON.stringify(packet);
      }
      if (packet.method === 'session.new') newSessionRequest = packet.id;
      if (packet.method === 'session.end') endingRequest = packet.id;
      socket.send(message);
    },
    close() { socket.close(); },
    onmessage: undefined,
    onclose: undefined,
    async shutdown() {
      if (socket.readyState === WebSocket.CLOSED) return;
      // Firefox retains sessions after a socket closes. If session.new succeeded
      // but Puppeteer initialization failed, end only our session on this same
      // original connection. Never attach to or end a session on a new socket.
      if (ownSession && socket.readyState === WebSocket.OPEN) {
        const ended = new Promise(resolve => { endResolver = resolve; });
        transport.send(JSON.stringify({ id: 2147483647, method: 'session.end', params: {} }));
        await Promise.race([ended, delay(1000)]);
      }
      const closed = new Promise(resolve => socket.once('close', resolve));
      socket.close();
      await Promise.race([closed, delay(500)]);
      if (socket.readyState !== WebSocket.CLOSED) socket.terminate();
      await closed;
    },
  };
  socket.on('message', data => {
    const text = data.toString();
    try {
      const packet = JSON.parse(text);
      if (packet.id === newSessionRequest && packet.type === 'success' && packet.result?.sessionId) ownSession = true;
      if (packet.id === endingRequest && packet.type === 'success') { ownSession = false; endResolver?.(); }
    } catch {}
    transport.onmessage?.(text);
  });
  socket.on('close', () => transport.onclose?.());
  return transport;
}

// A matched native prompt plus guarded UIA observations can exceed 15 seconds
// on a cold Windows desktop. Keep one bounded attempt, not a retry/reset loop.
export async function connectApproved(native, status, timeoutMs = 45000, connect = options => puppeteer.connect(options), transportFactory = openTransport) {
  const deadline = Date.now() + timeoutMs;
  const remaining = () => {
    const value = deadline - Date.now();
    if (value <= 0) throw new Error('F_CONNECTION_TIMEOUT');
    return value;
  };
  const nativeStep = async op => {
    remaining();
    // Do not abandon a queued native action. Complete its bounded RPC before
    // timing out and cleaning up; late completion can never mean success.
    const value = await native.request(op);
    remaining();
    return value;
  };
  const readWithinBudget = async read => {
    const budget = remaining();
    let timer;
    try {
      const value = await Promise.race([
        Promise.resolve().then(read),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('F_CONNECTION_TIMEOUT')), budget); }),
      ]);
      remaining();
      return value;
    } finally { clearTimeout(timer); }
  };
  remaining();
  await native.request('beginConsent');
  let transport;
  let browser;
  let consent = { seen: false, invoked: false, closed: false };
  let settled = false;
  let connectionFailure;
  let pending;
  let endIssued = false;
  try {
    transport = await transportFactory(`ws://127.0.0.1:${status.port}/session`, remaining());
    remaining();
    pending = Promise.resolve().then(() => connect({
      transport,
      protocol: 'webDriverBiDi',
      defaultViewport: null,
      acceptInsecureCerts: false,
      networkEnabled: false,
      capabilities: { unhandledPromptBehavior: 'ignore' },
      protocolTimeout: remaining(),
    })).then(value => { browser = value; settled = true; }, error => { connectionFailure = error; settled = true; });
    while (!settled) {
      // UIA crosses Firefox's main thread. Repeatedly enumerating every native
      // root after approval can starve BiDi initialization on busy desktops.
      // Keep the locked guard/watchers and the final consent/assert readback.
      if (!(consent.invoked && consent.closed)) consent = await nativeStep('pollConsent');
      await Promise.race([pending, delay(Math.min(100, remaining()))]);
    }
    remaining();
    if (connectionFailure) {
      // Error bodies can include URLs; only classify, never echo the original message.
      throw new Error(/Maximum number of active sessions|session.*already|already.*session/i.test(connectionFailure.message) ? 'F_SESSION_BUSY' : 'F_CONNECTION_FAILED');
    }
    consent = await nativeStep('pollConsent');
    if (consent.invoked && !consent.closed) throw new Error('F_CONSENT_NOT_CLOSED');
    if (!/^firefox\//i.test(await readWithinBudget(() => browser.version()))) throw new Error('F_BROWSER_UNEXPECTED');
    await nativeStep('assert');
    remaining();
    endIssued = true;
    await native.request('endConsent');
    remaining();
    return {
      browser,
      consent,
      async release() {
        try { await browser.disconnect(); }
        finally { await transport.shutdown(); }
      },
    };
  } catch (error) {
    const recordDisconnectFailure = () => {
      if (error && typeof error === 'object' && Object.isExtensible(error)) error.cleanupError ??= 'F_DISCONNECT_FAILED';
    };
    // A pending session.new must never survive a failed approval attempt.
    if (!endIssued) await native.request('cancelConsent').catch(() => {});
    // Give a successful in-flight handshake a chance to finish so the public
    // Browser.disconnect() can end it. The transport also covers partial init.
    if (pending && !settled) await Promise.race([pending, delay(300)]);
    if (browser) await browser.disconnect().catch(recordDisconnectFailure);
    if (transport) await transport.shutdown().catch(recordDisconnectFailure);
    if (!endIssued) await native.request('endConsent').catch(() => {});
    throw error;
  }
}
