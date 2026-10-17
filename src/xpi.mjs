import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const execute = promisify(execFile);

export async function inspectXpi(file) {
  if (!file || path.extname(file).toLowerCase() !== '.xpi') throw new Error('F_XPI_REQUIRED');
  const absolute = path.resolve(file);
  if (!(await stat(absolute).catch(() => null))?.isFile()) throw new Error('F_XPI_INVALID');
  let output;
  try {
    output = await execute('pwsh.exe', ['-NoProfile', '-NonInteractive', '-File', fileURLToPath(new URL('./inspect-xpi.ps1', import.meta.url)), '-ArchivePath', absolute], { windowsHide: true, timeout: 15000, maxBuffer: 16384 });
  } catch (error) {
    let code;
    try { code = JSON.parse(error.stdout.trim()).error; } catch {}
    throw new Error(code === 'F_XPI_ID_REQUIRED' ? code : 'F_XPI_INVALID');
  }
  let manifest;
  try { manifest = JSON.parse(output.stdout.trim()); } catch { throw new Error('F_XPI_INVALID'); }
  if (!manifest.ok || typeof manifest.id !== 'string' || !manifest.id || typeof manifest.version !== 'string' || !manifest.version) throw new Error('F_XPI_INVALID');
  const bytes = await readFile(absolute).catch(() => { throw new Error('F_XPI_INVALID'); });
  return { path: absolute, id: manifest.id, version: manifest.version, sha256: createHash('sha256').update(bytes).digest('hex') };
}
