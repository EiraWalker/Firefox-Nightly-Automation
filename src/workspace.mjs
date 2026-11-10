import { randomUUID } from 'node:crypto';
import { evaluateWithoutActivation } from './workspace-evaluate.mjs';

const fail = code => new Error(code);
const isId = value => typeof value === 'string' && value.length > 0;

// Adapter verified against the installed puppeteer-core 25.13.0 sources:
// src/bidi/Frame.ts assigns _id = browsingContext.id; Browser.connection.send
// returns the BiDi { result } envelope. Keep those private dependencies here.
function pageContextId(page) {
  const frame = page.mainFrame();
  const id = frame.browsingContext?.id;
  if (id !== undefined && frame._id !== undefined && id !== frame._id) throw fail('F_WORKSPACE_CONTEXT_IDENTITY');
  const value = id ?? frame._id;
  if (!isId(value)) throw fail('F_WORKSPACE_CONTEXT_IDENTITY');
  return value;
}

async function getTree(browser) {
  if (browser.connected !== true) throw fail('F_WORKSPACE_DISCONNECTED');
  let reply;
  try { reply = await browser.connection.send('browsingContext.getTree', { maxDepth: 0, 'moz:scope': 'content' }); }
  catch { throw fail('F_WORKSPACE_TREE_UNAVAILABLE'); }
  if (!Array.isArray(reply?.result?.contexts)) throw fail('F_WORKSPACE_TREE_INVALID');
  return reply.result.contexts;
}

function windowIdentity(entry) {
  const identity = {};
  for (const field of ['clientWindow', 'moz:window']) {
    if (entry?.[field] === undefined) continue;
    const value = entry[field];
    if (!isId(value) && !(field === 'moz:window' && Number.isSafeInteger(value) && value >= 0)) throw fail('F_WORKSPACE_WINDOW_IDENTITY');
    identity[field] = value;
  }
  if (!Object.keys(identity).length) throw fail('F_WORKSPACE_WINDOW_IDENTITY');
  return identity;
}

function ownEntry(tree, contextId, identity) {
  const matches = tree.filter(item => item.context === contextId);
  if (matches.length !== 1 || (matches[0].parent != null)) throw fail('F_WORKSPACE_OWNERSHIP_CHANGED');
  const entry = matches[0];
  if (identity && Object.entries(identity).some(([key, value]) => entry[key] !== value)) throw fail('F_WORKSPACE_OWNERSHIP_CHANGED');
  return entry;
}

// This is an API capability boundary, not a sandbox for arbitrary Node code.
// Never proxy the Puppeteer object itself: its own fields, prototypes, returns
// and event payloads can contain a connection or the user's BrowserContext.
function restricted(members) {
  const target = Object.create(null, Object.getOwnPropertyDescriptors(members));
  Object.freeze(target);
  return new Proxy(target, {
    get(object, key, receiver) {
      if (Object.hasOwn(object, key)) return Reflect.get(object, key, receiver);
      if (key === 'then' || key === 'toJSON' || typeof key === 'symbol') return undefined;
      throw fail('F_WORKSPACE_UNSUPPORTED');
    },
  });
}

function scopedResponse(response, assertWorkspace, assertLocal) {
  if (response == null) return null;
  const read = method => (...args) => { assertLocal(); return Reflect.apply(response[method], response, args); };
  const body = method => async (...args) => {
    await assertWorkspace();
    assertLocal();
    return Reflect.apply(response[method], response, args);
  };
  return restricted({
    status: read('status'), statusText: read('statusText'),
    url: read('url'), ok: read('ok'), headers: () => { assertLocal(); return { ...response.headers() }; },
    text: body('text'), json: body('json'),
  });
}

function scopedApi(rawBrowser, rawPage, contextId, assertWorkspace, assertLocal) {
  let browser;
  let context;
  let target;
  let primaryClaimed = false;
  const connected = () => { try { assertLocal(); return true; } catch { return false; } };
  const newPage = async options => {
    if (options !== undefined) throw fail('F_WORKSPACE_PAGE_OPTIONS_UNSUPPORTED');
    await assertWorkspace();
    assertLocal();
    if (primaryClaimed) throw fail('F_WORKSPACE_SINGLE_PAGE');
    primaryClaimed = true;
    return page;
  };
  const denied = () => { throw fail('F_WORKSPACE_FORBIDDEN'); };
  const guarded = method => async (...args) => {
    await assertWorkspace();
    assertLocal();
    // Real receiver is mandatory: BidiPage uses JavaScript #private fields.
    return Reflect.apply(rawPage[method], rawPage, args);
  };
  const page = restricted({
    browser: () => browser,
    browserContext: () => context,
    target: () => target,
    isClosed: () => rawPage.isClosed(),
    url: () => { assertLocal(); return rawPage.url(); },
    title: guarded('title'),
    async evaluate(...args) {
      await assertWorkspace();
      assertLocal();
      try { return await evaluateWithoutActivation(rawBrowser, contextId, ...args); }
      finally { await assertWorkspace(); }
    },
    async goto(...args) { return scopedResponse(await guarded('goto')(...args), assertWorkspace, assertLocal); },
    setContent: guarded('setContent'),
    content: guarded('content'),
    close: denied,
    bringToFront: denied,
  });
  target = restricted({
    browser: () => browser, browserContext: () => context,
    page: async () => { await assertWorkspace(); return page; },
    type: () => 'page', url: () => page.url(), opener: () => undefined,
  });
  const pages = async () => { await assertWorkspace(); return [page]; };
  context = restricted({ browser: () => browser, pages, newPage, targets: () => [target], close: denied });
  browser = restricted({
    page, pages, newPage,
    defaultBrowserContext: () => context,
    browserContexts: () => [context], targets: () => [target],
    async version() { await assertWorkspace(); assertLocal(); return rawBrowser.version(); },
    isConnected: connected,
    get connected() { return connected(); },
    close: denied, disconnect: denied,
  });
  return { browser, page };
}

/**
 * A single-page default-profile task window, not a full Puppeteer Browser.
 * browser.page is the primary scoped Page; the first parameterless newPage()
 * (shared with defaultBrowserContext()) aliases it, never opens another tab.
 * Supported Page operations: evaluate, goto, setContent, content, title, url,
 * isClosed and scoped browser/browserContext/target accessors. Raw handles,
 * frames, event payloads and global/profile/window controls are unsupported.
 * The caller owns finally { await workspace.close(); }; tasks must not close it.
 */
export async function createTaskWorkspace(browser, native, { allowCreationActivation = true, allowInspectionActivation = false } = {}) {
  if (typeof allowCreationActivation !== 'boolean' || typeof allowInspectionActivation !== 'boolean') throw fail('F_WORKSPACE_OPTIONS_INVALID');
  const token = randomUUID();
  let page;
  let contextId;
  let identity;
  let hwnd;
  let attemptedCreation = false;
  let knownUserObject = false;
  let canCleanup = false;
  let closed = false;
  let revoked = false;
  let closePromise;
  let assertionFailure;
  const coded = (error, fallback) => fail(/^F_[A-Z_]+$/.test(error?.message) ? error.message : fallback);
  const assertLocal = () => {
    if (revoked) throw fail(closed ? 'F_WORKSPACE_CLOSED' : 'F_WORKSPACE_CLOSING');
    if (assertionFailure) throw assertionFailure;
    if (browser.connected !== true) assertionFailure = fail('F_WORKSPACE_DISCONNECTED');
    else if (page.isClosed()) assertionFailure = fail('F_WORKSPACE_OWNERSHIP_CHANGED');
    if (assertionFailure) throw assertionFailure;
  };
  const verifyOwnership = async () => {
    if (page.isClosed() || pageContextId(page) !== contextId) throw fail('F_WORKSPACE_OWNERSHIP_CHANGED');
    ownEntry(await getTree(browser), contextId, identity);
  };
  const assertWorkspace = async () => {
    assertLocal();
    try {
      await verifyOwnership();
      await native.request('assert');
      await verifyOwnership();
      assertLocal();
    } catch (error) {
      assertionFailure = coded(error, 'F_WORKSPACE_ASSERT_FAILED');
      throw assertionFailure;
    }
  };
  const closeOwned = async () => {
    // Cleanup deliberately bypasses a failed task/native assert, but NEVER the
    // exact page/context/window ownership check. Do not close a context/window.
    await verifyOwnership();
    if (hwnd !== undefined) await native.request('beginWorkspaceClose', { token, hwnd });
    let failure;
    try {
      await verifyOwnership();
      await page.close({ runBeforeUnload: false });
      const remaining = await getTree(browser);
      if (remaining.some(item => item.context === contextId)) throw fail('F_WORKSPACE_PAGE_REMAINS');
    } catch (error) { failure = coded(error, 'F_WORKSPACE_CLOSE_FAILED'); }
    if (hwnd !== undefined) {
      try {
        const receipt = await native.request('finishWorkspaceClose', { token, hwnd });
        if (receipt?.closed === false) throw fail('F_WORKSPACE_WINDOW_REMAINS');
        if (receipt?.closed !== true) throw fail('F_WORKSPACE_CLOSE_UNCONFIRMED');
      } catch (error) { failure = coded(error, 'F_WORKSPACE_CLOSE_UNCONFIRMED'); }
    }
    if (failure) throw failure;
  };
  const close = () => {
    if (!closePromise) {
      revoked = true;
      closePromise = closeOwned().then(() => { closed = true; });
    }
    return closePromise;
  };
  try {
    await native.request('beginWorkspace', { token, allowCreationActivation, allowInspectionActivation });
    const before = await getTree(browser);
    const previousWindows = before.map(windowIdentity);
    attemptedCreation = true;
    page = await browser.defaultBrowserContext().newPage({ type: 'window', background: true });
    contextId = pageContextId(page);
    knownUserObject = before.some(item => item.context === contextId);
    if (knownUserObject) throw fail('F_WORKSPACE_NOT_NEW');
    const entry = ownEntry(await getTree(browser), contextId);
    identity = windowIdentity(entry);
    canCleanup = true;
    for (const previous of previousWindows) {
      const comparable = Object.keys(identity).filter(key => Object.hasOwn(previous, key));
      if (!comparable.length) throw fail('F_WORKSPACE_WINDOW_IDENTITY');
      if (comparable.some(key => previous[key] === identity[key])) throw fail('F_WORKSPACE_NOT_NEW_WINDOW');
    }
    if (entry.url !== 'about:blank' || page.url() !== 'about:blank') throw fail('F_WORKSPACE_NOT_BLANK');
    const marker = `Hermes Task Workspace ${token}`;
    await verifyOwnership();
    await page.evaluate(title => {
      if (document.documentURI !== 'about:blank') throw new Error('F_WORKSPACE_NOT_BLANK');
      document.title = title;
    }, marker);
    const registration = await native.request('registerWorkspace', { token, marker });
    const handle = registration?.hwnd;
    const validString = typeof handle === 'string' && (/^[1-9][0-9]*$/.test(handle) || (/^0x[0-9a-fA-F]+$/.test(handle) && !/^0x0+$/.test(handle)));
    if (!validString && !(Number.isSafeInteger(handle) && handle > 0)) throw fail('F_WORKSPACE_REGISTRATION_INVALID');
    hwnd = handle;
    await assertWorkspace();
    const scoped = scopedApi(browser, page, contextId, assertWorkspace, assertLocal);
    return Object.freeze({
      browser: scoped.browser,
      page: scoped.page,
      info: Object.freeze({ token, contextId, ...identity, hwnd }),
      assert: assertWorkspace,
      close,
    });
  } catch (error) {
    const failure = coded(error, 'F_WORKSPACE_CREATE_FAILED');
    if (canCleanup) {
      try { await closeOwned(); }
      catch (cleanupError) { failure.cleanupError = coded(cleanupError, 'F_WORKSPACE_CLOSE_FAILED').message; }
    } else if (attemptedCreation && !knownUserObject) {
      // newPage may reject after a remote create, or return an unsupported page.
      // Never infer ownership from a URL, title, or a difference of page lists.
      failure.cleanupError = 'F_WORKSPACE_CLEANUP_UNPROVEN';
    }
    throw failure;
  }
}
