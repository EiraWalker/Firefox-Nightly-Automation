import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { access } from 'node:fs/promises';

const execute = promisify(execFile);
export async function resetSharedSession(native) {
  const endpoint = await native.request('marionetteEndpoint');
  if (!endpoint.listening || !endpoint.verified) throw new Error('F_MARIONETTE_ENDPOINT_UNSAFE');
  await native.request('assert');
  await native.request('closeResetConsent');
  const python = fileURLToPath(new URL('../.venv/Scripts/python.exe', import.meta.url));
  await access(python).catch(() => { throw new Error('F_PYTHON_DEPENDENCY_MISSING'); });
  let output;
  try {
    output = await execute(python, [fileURLToPath(new URL('./reset_session.py', import.meta.url))], { windowsHide: true, timeout: 15000, maxBuffer: 65536 });
  } catch { throw new Error('F_SESSION_RESET_FAILED'); }
  let result;
  try { result = JSON.parse(output.stdout.trim()); } catch { throw new Error('F_SESSION_RESET_FAILED'); }
  if (!result.ok || (!result.deleteSessionCompleted && !result.sessionAlreadyClear)) throw new Error('F_SESSION_RESET_FAILED');
  await native.request('assert');
  return result;
}
