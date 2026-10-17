import puppeteer from 'puppeteer-core';
import WebSocket from 'ws';

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

// Public Puppeteer ConnectionTransport interface; the WebDriver protocol stays upstream.
export async function openTransport(endpoint, timeoutMs) {
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

export async function connectApproved(native, status, timeoutMs = 15000, connect = options => puppeteer.connect(options), transportFactory = openTransport) {
  await native.request('beginConsent');
  let transport;
  let browser;
  let consent = { seen: false, invoked: false, closed: false };
  let settled = false;
  let connectionFailure;
  let pending;
  try {
    transport = await transportFactory(`ws://127.0.0.1:${status.port}/session`, timeoutMs);
    pending = Promise.resolve().then(() => connect({
      transport,
      protocol: 'webDriverBiDi',
      defaultViewport: null,
      acceptInsecureCerts: false,
      networkEnabled: false,
      capabilities: { unhandledPromptBehavior: 'ignore' },
      protocolTimeout: timeoutMs,
    })).then(value => { browser = value; settled = true; }, error => { connectionFailure = error; settled = true; });
    const deadline = Date.now() + timeoutMs;
    while (!settled) {
      consent = await native.request('pollConsent');
      if (Date.now() >= deadline) throw new Error('F_CONNECTION_TIMEOUT');
      await Promise.race([pending, delay(100)]);
    }
    if (connectionFailure) {
      // Error bodies can include URLs; only classify, never echo the original message.
      throw new Error(/Maximum number of active sessions|session.*already|already.*session/i.test(connectionFailure.message) ? 'F_SESSION_BUSY' : 'F_CONNECTION_FAILED');
    }
    consent = await native.request('pollConsent');
    if (consent.invoked && !consent.closed) throw new Error('F_CONSENT_NOT_CLOSED');
    if (!/^firefox\//i.test(await browser.version())) throw new Error('F_BROWSER_UNEXPECTED');
    await native.request('assert');
    await native.request('endConsent');
    return {
      browser,
      consent,
      async release() {
        try { await browser.disconnect(); }
        finally { await transport.shutdown(); }
      },
    };
  } catch (error) {
    // A pending session.new must never survive a failed approval attempt.
    await native.request('cancelConsent').catch(() => {});
    // Give a successful in-flight handshake a chance to finish so the public
    // Browser.disconnect() can end it. The transport also covers partial init.
    if (pending && !settled) await Promise.race([pending, delay(300)]);
    if (browser) await browser.disconnect().catch(() => {});
    if (transport) await transport.shutdown();
    await native.request('endConsent').catch(() => {});
    throw error;
  }
}
