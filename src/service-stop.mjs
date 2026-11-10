// The caller must hold its own exclusive BiDi session and verify service ownership.
// A true return means one stop was requested, NOT that shutdown was confirmed.
const chromeUrl = 'chrome://browser/content/browser.xhtml';
const probe = `() => {
  if (document.documentURI !== 'chrome://browser/content/browser.xhtml') return false;
  const {RemoteControlServers} = ChromeUtils.importESModule('moz-src:///browser/components/remotecontrol/RemoteControlServers.sys.mjs');
  return RemoteControlServers.runningDynamically === true && RemoteControlServers.hasActiveSession === true && typeof RemoteControlServers.stop === 'function';
}`;
const stop = `() => {
  if (document.documentURI !== 'chrome://browser/content/browser.xhtml') return false;
  const {RemoteControlServers} = ChromeUtils.importESModule('moz-src:///browser/components/remotecontrol/RemoteControlServers.sys.mjs');
  if (!RemoteControlServers.runningDynamically || !RemoteControlServers.hasActiveSession) return false;
  RemoteControlServers.stop().catch(() => {});
  return true;
}`;

export async function requestProtocolStop(browser, assertDesktop) {
  if (typeof browser?.connection?.send !== 'function') return false;
  let context;
  try {
    const {result} = await browser.connection.send('browsingContext.getTree', {'moz:scope': 'chrome', maxDepth: 0});
    context = result.contexts.find(item => item.url === chromeUrl)?.context;
    if (typeof context !== 'string' || !context) return false;
    const {result: reply} = await browser.connection.send('script.callFunction', {
      functionDeclaration: probe, target: {context}, awaitPromise: true, resultOwnership: 'none',
    });
    if (reply.type !== 'success' || reply.result?.type !== 'boolean' || reply.result.value !== true) return false;
  } catch {
    // Missing system access / restricted sessions keep the existing native path.
    return false;
  }
  await assertDesktop();
  try {
    await browser.connection.send('script.callFunction', {
      functionDeclaration: stop, target: {context}, awaitPromise: true, resultOwnership: 'none',
    });
  } catch {
    // Stopping the server can close this very socket before its reply arrives.
    // After dispatch, NEVER fall back/replay: the caller independently reads state.
  }
  return true;
}
