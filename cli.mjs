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
const store = new OwnershipStore(path.join(root, '.local'));
const args = process.argv.slice(2);
const action = args.shift();
let native;
let unlock;
let response;
let automation;
try {
  if (!['status', 'start', 'stop', 'restart', 'reset-session', 'run', 'install'].includes(action)) throw new Error('F_INVALID_ACTION');
  const config = { executablePath: 'C:\\Program Files\\Firefox Nightly\\firefox.exe', port: 9222 };
  let taskFile;
  let xpiFile;
  let resetExisting = false;
  let restartService = false;
  while (args.length) {
    const option = args.shift();
    if (option === '--hwnd') config.hwnd = args.shift();
    else if (option === '--port') config.port = Number(args.shift());
    else if (option === '--executable') config.executablePath = args.shift();
    else if (option === '--task') taskFile = args.shift();
    else if (option === '--xpi') xpiFile = args.shift();
    else if (option === '--reset-existing') resetExisting = true;
    else if (option === '--restart-service') restartService = true;
    else throw new Error('F_INVALID_ARGUMENT');
  }
  if (!Number.isInteger(config.port) || config.port < 1 || config.port > 65535 || !config.executablePath || (config.hwnd !== undefined && !/^0x[0-9a-f]+$/i.test(config.hwnd))) throw new Error('F_INVALID_ARGUMENT');
  if (action === 'run' && !taskFile) throw new Error('F_TASK_REQUIRED');
  if ((action === 'install' && !xpiFile) || (xpiFile && action !== 'install')) throw new Error('F_XPI_REQUIRED');
  if (resetExisting && !['restart', 'reset-session'].includes(action)) throw new Error('F_INVALID_ARGUMENT');
  if (restartService && action !== 'restart') throw new Error('F_INVALID_ARGUMENT');
  if (['restart', 'reset-session'].includes(action) && !resetExisting) throw new Error('F_RESET_AUTHORIZATION_REQUIRED');
  const task = action === 'run' ? (await import(pathToFileURL(path.resolve(taskFile)).href)).default : null;
  if (action === 'run' && typeof task !== 'function') throw new Error('F_TASK_INVALID');
  const artifact = action === 'install' ? await inspectXpi(xpiFile) : null;
  if (action !== 'status') unlock = await store.lock();
  native = new NativeWindows(config);
  await native.ready();
  automation = new NightlyAutomation({ native, store, connect: connectApproved, resetSession: resetSharedSession });
  const data = action === 'run' ? await automation.run(task)
    : action === 'install' ? await automation.install(artifact)
    : action === 'restart' ? await automation.restart({ resetExisting, restartService })
    : action === 'reset-session' ? await automation.reset({ resetExisting })
    : await automation[action]();
  const background = await native.request(action === 'status' ? 'report' : 'assert');
  response = { ok: true, action, data, background };
} catch (error) {
  const code = /^F_[A-Z_]+$/.test(error.message) ? error.message : 'F_OPERATION_FAILED';
  response = { ok: false, action, error: code };
  if (automation) response.completedStages = automation.completedStages;
  if (native) response.background = await native.request('report').catch(() => ({ available: false }));
  if (native) response.status = await native.request('status').catch(() => null);
  process.exitCode = 1;
} finally {
  if (native) response.nativeTrace = native.trace;
  if (native) await native.close();
  if (unlock) await unlock();
}
const reportName = `${new Date().toISOString().replace(/[:.]/g, '-')}-${randomUUID()}.json`;
try {
  const directory = path.join(root, '.local', 'runs');
  await mkdir(directory, { recursive: true });
  const report = structuredClone(response);
  if (report.data) delete report.data.task;
  await writeFile(path.join(directory, reportName), JSON.stringify(report, null, 2), { mode: 0o600 });
  response.report = path.join(directory, reportName);
} catch { response.report = null; }
console.log(JSON.stringify(response));
