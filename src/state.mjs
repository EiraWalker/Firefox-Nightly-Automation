import { mkdir, readFile, writeFile, open, unlink } from 'node:fs/promises';
import path from 'node:path';

export class OwnershipStore {
  constructor(directory) { this.directory = directory; this.file = path.join(directory, 'ownership.json'); }
  async read() {
    try { return JSON.parse(await readFile(this.file, 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return null; throw new Error('F_STATE_INVALID'); }
  }
  async write(value) {
    await mkdir(this.directory, { recursive: true });
    await writeFile(this.file, JSON.stringify(value, null, 2), { mode: 0o600 });
  }
  async clear() { await unlink(this.file).catch(error => { if (error.code !== 'ENOENT') throw error; }); }
  async lock() {
    await mkdir(this.directory, { recursive: true });
    const file = path.join(this.directory, 'operation.lock');
    let handle;
    try { handle = await open(file, 'wx'); }
    catch (error) { if (error.code === 'EEXIST') throw new Error('F_OPERATION_BUSY'); throw error; }
    await handle.writeFile(JSON.stringify({ pid: process.pid, created: new Date().toISOString() }));
    return async () => { await handle.close(); await unlink(file); };
  }
}

export function ownsService(record, status) {
  return !!record && record.phase === 'running' &&
    record.browser.processId === status.browser.processId &&
    record.browser.created === status.browser.created &&
    record.browser.executablePath.toLowerCase() === status.browser.executablePath.toLowerCase() &&
    record.port === status.port &&
    JSON.stringify(record.endpointCreated) === JSON.stringify(status.endpoint.created);
}
