import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

export class NativeWindows {
  #child;
  #ready = Promise.withResolvers();
  #pending = new Map();
  #counter = 0;
  #closing = false;
  trace = [];
  constructor({ executablePath, port, hwnd }) {
    const args = ['-NoProfile', '-NonInteractive', '-File', fileURLToPath(new URL('./native.ps1', import.meta.url)), '-ExecutablePath', executablePath, '-Port', String(port)];
    if (hwnd) args.push('-Hwnd', hwnd);
    this.#child = spawn('pwsh.exe', args, { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    // Native provider exceptions may contain private window names. Only coded JSON is used.
    this.#child.stderr.resume();
    const lines = createInterface({ input: this.#child.stdout });
    lines.on('line', line => {
      let message;
      try { message = JSON.parse(line); } catch { return this.#fail('F_NATIVE_PROTOCOL'); }
      if ('ready' in message) {
        this.trace.push({ op: 'initialize', ok: message.ready, ...(message.error ? { error: message.error } : {}) });
        if (message.ready) this.#ready.resolve();
        else this.#fail(message.error);
        return;
      }
      const pending = this.#pending.get(message.id);
      if (!pending) return;
      this.#pending.delete(message.id);
      this.trace.push({ op: pending.op, ok: message.ok, ...(message.error ? { error: message.error } : {}) });
      clearTimeout(pending.timer);
      if (message.ok) pending.resolve(message.data);
      else pending.reject(new Error(message.error));
    });
    this.#child.on('error', () => this.#fail('F_NATIVE_UNAVAILABLE'));
    this.#child.on('exit', () => { if (!this.#closing) this.#fail('F_NATIVE_EXITED'); });
  }
  #fail(code) {
    const error = new Error(/^F_[A-Z_]+$/.test(code) ? code : 'F_NATIVE_UNAVAILABLE');
    this.#ready.reject(error);
    for (const pending of this.#pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.#pending.clear();
  }
  async ready() {
    let timer;
    try {
      await Promise.race([this.#ready.promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('F_NATIVE_TIMEOUT')), 20000); })]);
    } finally { clearTimeout(timer); }
  }
  async request(op, payload = {}) {
    await this.ready();
    const id = ++this.#counter;
    const result = new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.#pending.delete(id); reject(new Error('F_NATIVE_TIMEOUT')); }, 20000);
      this.#pending.set(id, { resolve, reject, timer, op });
    });
    this.#child.stdin.write(`${JSON.stringify({ id, op, ...payload })}\n`);
    return result;
  }
  async close() {
    this.#closing = true;
    this.#child.stdin.end();
    if (this.#child.exitCode !== null) return;
    let timer;
    try {
      await Promise.race([
        new Promise(resolve => this.#child.once('exit', resolve)),
        new Promise(resolve => { timer = setTimeout(() => { this.#child.kill(); resolve(); }, 3000); }),
      ]);
    } finally { clearTimeout(timer); }
  }
}
