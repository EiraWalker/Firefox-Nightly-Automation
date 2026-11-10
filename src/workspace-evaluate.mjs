// Private adapter for the package.json-locked puppeteer-core 25.13.0.
// Its exported internal codecs are reused; BidiRealm.evaluate cannot be used
// because it unconditionally requests userActivation:true for both forms.
import { BidiSerializer } from 'puppeteer-core/internal/bidi/Serializer.js';
import { BidiDeserializer } from 'puppeteer-core/internal/bidi/Deserializer.js';
import { stringifyFunction } from 'puppeteer-core/internal/util/Function.js';
import { createEvaluationError, rewriteEvaluationError } from 'puppeteer-core/internal/bidi/util.js';

const unsupported = () => new Error('F_WORKSPACE_EVALUATE_UNSUPPORTED');

// Deliberate data-only subset: JSON plus undefined (including void results).
// Reject rather than silently lose handles, accessors, sparse data or cycles.
function assertData(value, ancestors = new Set()) {
  if (value == null || ['string', 'boolean', 'undefined'].includes(typeof value)) return;
  if (typeof value === 'number' && Number.isFinite(value)) return;
  if (typeof value !== 'object' || ancestors.has(value)) throw unsupported();
  const array = Array.isArray(value);
  if (Object.getPrototypeOf(value) !== (array ? Array.prototype : Object.prototype)) throw unsupported();
  ancestors.add(value);
  const keys = Reflect.ownKeys(value).filter(key => !(array && key === 'length'));
  if (array && keys.length !== value.length) throw unsupported();
  for (const key of keys) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (typeof key !== 'string' || key === '__proto__' || !descriptor.enumerable || !Object.hasOwn(descriptor, 'value')) throw unsupported();
    if (array && (!/^(0|[1-9][0-9]*)$/.test(key) || Number(key) >= value.length)) throw unsupported();
    assertData(descriptor.value, ancestors);
  }
  ancestors.delete(value);
}

function assertRemoteData(remote) {
  if (!remote || typeof remote !== 'object' || 'handle' in remote || 'sharedId' in remote) throw unsupported();
  switch (remote.type) {
    case 'null': case 'undefined': return;
    case 'string': if (typeof remote.value === 'string') return; break;
    case 'boolean': if (typeof remote.value === 'boolean') return; break;
    case 'number': if (Number.isFinite(remote.value) || remote.value === '-0') return; break;
    case 'array':
      if (!Array.isArray(remote.value)) break;
      for (const value of remote.value) assertRemoteData(value);
      return;
    case 'object':
      if (!Array.isArray(remote.value)) break;
      for (const tuple of remote.value) {
        if (!Array.isArray(tuple) || tuple.length !== 2) throw unsupported();
        const [key, value] = tuple;
        const name = typeof key === 'string' ? key : key?.type === 'string' ? key.value : undefined;
        // The installed deserializer assigns object keys; never let __proto__
        // mutate its accumulator. Unsupported data fails explicitly, not lossy.
        if (typeof name !== 'string' || name === '__proto__') throw unsupported();
        assertRemoteData(value);
      }
      return;
  }
  throw unsupported();
}

export async function evaluateWithoutActivation(browser, contextId, pageFunction, ...args) {
  const expression = typeof pageFunction === 'string';
  let script;
  try {
    if (!expression && typeof pageFunction !== 'function') throw unsupported();
    if (expression && args.length) throw unsupported();
    if (expression) script = { expression: pageFunction };
    else {
      const functionDeclaration = stringifyFunction(pageFunction);
      // Validate syntax without executing the task locally (reject native/bound).
      new Function(`return (${functionDeclaration})`);
      for (const arg of args) assertData(arg);
      script = { functionDeclaration, arguments: args.map(arg => BidiSerializer.serialize(arg)) };
    }
  } catch { throw unsupported(); }
  const params = {
    target: { context: contextId },
    awaitPromise: true,
    resultOwnership: 'none',
    userActivation: false,
    serializationOptions: {},
    ...script,
  };
  // WindowRealm.target uses a browsing context, not a cached realm id, so a
  // later navigation evaluates in the owned context's current default realm.
  const { result } = await browser.connection.send(expression ? 'script.evaluate' : 'script.callFunction', params).catch(rewriteEvaluationError);
  if (result?.type === 'exception') throw createEvaluationError(result.exceptionDetails);
  if (result?.type !== 'success') throw unsupported();
  assertRemoteData(result.result);
  return BidiDeserializer.deserialize(result.result);
}
