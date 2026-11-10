#!/usr/bin/env node
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { mkdir, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { NativeWindows } from './src/windows.mjs';
import { OwnershipStore } from './src/state.mjs';
import { connectApproved } from './src/connection.mjs';
import { NightlyAutomation } from './src/automation.mjs';
import { resetSharedSession } from './src/reset.mjs';
import { inspectXpi } from './src/xpi.mjs';

const root = path.dirname(fileURLToPath(import.meta.url));
const errorCode = error => /^F_[A-Z_]+$/.test(error?.message) ? error.message : 'F_OPERATION_FAILED';

// Dependencies keep CLI lifecycle/reporting testable without a real desktop.
export async function runCli(argv, {
  store = new OwnershipStore(path.join(root, '.local')),
  createNative = config => new NativeWindows(config),
  connect = connectApproved,
  createWorkspace,
  resetSession = resetSharedSession,
  inspectArtifact = inspectXpi,
  loadTask = async file => (await import(pathToFileURL(path.resolve(file)).href)).default,
  reportDirectory = path.join(root, '.local', 'runs'),
} = {}) {
  const args = [...argv];
  const action = args.shift();
  let native;
  let unlock;
  let response;
  let automation;
  let data;
  let artifact;
  try {
    if (!['status', 'start', 'stop', 'restart', 'reset-session', 'run', 'install', 'verify'].includes(action)) throw new Error('F_INVALID_ACTION');
    const config = { executablePath: 'C:\\Program Files\\Firefox Nightly\\firefox.exe', port: 9222, workspaceGuard: action === 'run' };
    let taskFile;
    let xpiFile;
    let addonId;
    let resetExisting = false;
    let restartService = false;
    let denyPendingConsent = false;
    let allowWorkspaceCreationActivation = true;
    while (args.length) {
      const option = args.shift();
      if (option === '--hwnd') config.hwnd = args.shift();
      else if (option === '--port') config.port = Number(args.shift());
      else if (option === '--executable') config.executablePath = args.shift();
      else if (option === '--task') taskFile = args.shift();
      else if (option === '--xpi') xpiFile = args.shift();
      else if (option === '--id') {
        addonId = args.shift();
        if (!addonId || addonId.startsWith('--')) throw new Error('F_INVALID_ARGUMENT');
      }
      else if (option === '--reset-existing') resetExisting = true;
      else if (option === '--restart-service') restartService = true;
      else if (option === '--deny-pending-consent') denyPendingConsent = true;
      else if (option === '--no-workspace-activation') allowWorkspaceCreationActivation = false;
      else throw new Error('F_INVALID_ARGUMENT');
    }
    if (!Number.isInteger(config.port) || config.port < 1 || config.port > 65535 || !config.executablePath || (config.hwnd !== undefined && !/^0x[0-9a-f]+$/i.test(config.hwnd))) throw new Error('F_INVALID_ARGUMENT');
    if (action === 'run' && !taskFile) throw new Error('F_TASK_REQUIRED');
    if (addonId && (action !== 'verify' || xpiFile)) throw new Error('F_INVALID_ARGUMENT');
    if (action === 'verify' && !xpiFile && !addonId) throw new Error('F_VERIFY_TARGET_REQUIRED');
    if ((action === 'install' && !xpiFile) || (xpiFile && !['install', 'verify'].includes(action))) throw new Error('F_XPI_REQUIRED');
    if (resetExisting && !['restart', 'reset-session'].includes(action)) throw new Error('F_INVALID_ARGUMENT');
    if (restartService && action !== 'restart') throw new Error('F_INVALID_ARGUMENT');
    if (denyPendingConsent && !['run', 'install', 'start'].includes(action)) throw new Error('F_INVALID_ARGUMENT');
    if (!allowWorkspaceCreationActivation && action !== 'run') throw new Error('F_INVALID_ARGUMENT');
    if (['restart', 'reset-session'].includes(action) && !resetExisting) throw new Error('F_RESET_AUTHORIZATION_REQUIRED');
    const task = action === 'run' ? await loadTask(taskFile) : null;
    if (action === 'run' && typeof task !== 'function') throw new Error('F_TASK_INVALID');
    artifact = xpiFile ? await inspectArtifact(xpiFile) : null;
    if (action !== 'status') unlock = await store.lock();
    native = createNative(config);
    await native.ready();
    automation = new NightlyAutomation({ native, store, connect, resetSession, createWorkspace });
    data = action === 'run' ? await automation.run(task, { denyPendingConsent, allowWorkspaceCreationActivation })
      : action === 'install' ? await automation.install(artifact, { denyPendingConsent })
      : action === 'start' ? await automation.start({ denyPendingConsent })
      : action === 'verify' ? await automation.verify(artifact ?? { id: addonId })
      : action === 'restart' ? await automation.restart({ resetExisting, restartService })
      : action === 'reset-session' ? await automation.reset({ resetExisting })
      : await automation[action]();
    const background = await native.request(action === 'status' ? 'report' : 'assert');
    response = { ok: true, action, data, background };
  } catch (error) {
    const code = errorCode(error);
    response = { ok: false, action, error: code };
    const retained = error.data ?? data;
    if (retained) response.data = retained;
    if (artifact && action === 'install' && !response.data?.installation) {
      response.data = { ...response.data, installation: { permanent: true, status: 'not-started', archiveInstalled: false, artifact: { id: artifact.id, version: artifact.version, sha256: artifact.sha256 } } };
    }
    if (error.taskError) response.taskError = error.taskError;
    if (error.cleanupError || data) response.cleanupError = error.cleanupError ?? code;
    if (error.cleanupErrors?.length) response.cleanupErrors = error.cleanupErrors;
    else if (data) response.cleanupErrors = [{ stage: 'final-assert', code }];
    if (automation) response.completedStages = automation.completedStages;
    if (native) response.background = await native.request('report').catch(() => ({ available: false }));
    if (native) response.status = await native.request('status').catch(() => null);
  } finally {
    const cleanupFailed = (stage, error) => {
      const code = errorCode(error);
      (response.cleanupErrors ??= []).push({ stage, code });
      if (!response.cleanupError) {
        if (!response.ok && !response.taskError) response.operationError = response.error;
        response.error = code;
        response.cleanupError = code;
      }
      response.ok = false;
      if (automation) response.completedStages = automation.completedStages;
    };
    if (native) response.nativeTrace = native.trace;
    if (native) {
      try { await native.close(); } catch (error) { cleanupFailed('native-close', error); }
    }
    if (unlock) {
      try { await unlock(); } catch (error) { cleanupFailed('lock-release', error); }
    }
  }
  const reportName = `${new Date().toISOString().replace(/[:.]/g, '-')}-${randomUUID()}.json`;
  try {
    await mkdir(reportDirectory, { recursive: true });
    // Task values are returned only to the caller, never stored in diagnostics.
    const { task: omittedTask, ...safeData } = response.data ?? {};
    const report = structuredClone({ ...response, ...(response.data ? { data: safeData } : {}) });
    await writeFile(path.join(reportDirectory, reportName), JSON.stringify(report, null, 2), { mode: 0o600 });
    response.report = path.join(reportDirectory, reportName);
  } catch { response.report = null; }
  return response;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const response = await runCli(process.argv.slice(2));
  process.exitCode = response.ok ? 0 : 1;
  console.log(JSON.stringify(response));
}
