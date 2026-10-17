import { ownsService } from './state.mjs';
import { installPermanentAddon } from './addons.mjs';

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

export class NightlyAutomation {
  constructor({ native, store, connect, resetSession }) {
    this.native = native; this.store = store; this.connect = connect; this.resetSession = resetSession;
    this.completedStages = [];
  }
  async status() {
    const status = await this.native.request('status');
    return { ...status, owned: ownsService(await this.store.read(), status) };
  }
  async #ensureRunning() {
    const status = await this.status();
    if (status.endpoint.listening) {
      if (!status.endpoint.verified) throw new Error('F_ENDPOINT_UNSAFE');
      if (!status.toolbarRunning) throw new Error('F_REMOTE_CONTROL_STATE_UNKNOWN');
      return { status, startedHere: false };
    }
    if (status.toolbarRunning) throw new Error('F_REMOTE_CONTROL_INCONSISTENT');
    if (!status.toolbarAvailable) throw new Error('F_REMOTE_CONTROL_BUTTON_UNAVAILABLE');
    const previous = await this.store.read();
    await this.store.write({ phase: 'starting', browser: status.browser, port: status.port });
    try {
      await this.native.request('power', { enabled: true });
      const running = await this.#waitPower(true);
      await this.store.write({ phase: 'running', browser: running.browser, port: running.port, endpointCreated: running.endpoint.created });
      if (this.completedStages.includes('service-stopped')) this.completedStages.push('service-started');
      return { status: { ...running, owned: true }, startedHere: true };
    } catch (error) {
      // Keep uncertain ownership if a provider acted before failing; never blindly toggle again.
      const after = await this.native.request('status').catch(() => null);
      if (after && !after.endpoint.listening && !after.toolbarRunning) {
        if (previous) await this.store.write(previous); else await this.store.clear();
      }
      throw error;
    }
  }
  async #waitPower(enabled) {
    const deadline = Date.now() + 10000;
    do {
      const status = await this.native.request('status');
      await this.native.request('assert');
      if (enabled && status.endpoint.verified && status.toolbarRunning) return status;
      if (!enabled && !status.endpoint.listening && !status.toolbarRunning) return status;
      await delay(200);
    } while (Date.now() < deadline);
    throw new Error('F_POWER_NOT_CONFIRMED');
  }
  async #stopOwnedWithSession(status) {
    const current = await this.status();
    if (!ownsService(await this.store.read(), current) || current.browser.created !== status.browser.created) throw new Error('F_OWNERSHIP_CHANGED');
    // The owned BiDi session remains connected until the native stop command executes.
    // Firefox permits only one active WebDriver session, so this cannot disconnect another one.
    await this.native.request('power', { enabled: false });
    const stopped = await this.#waitPower(false);
    await this.store.clear();
    return stopped;
  }
  async start() {
    const running = await this.#ensureRunning();
    const session = await this.connect(this.native, running.status);
    try {
      return { startedHere: running.startedHere, owned: running.status.owned, handshake: true, consent: session.consent, status: await this.status() };
    } finally { await session.release(); }
  }
  async stop() {
    const status = await this.status();
    if (!status.endpoint.listening) {
      if (status.owned) await this.store.clear();
      return { stopped: false, reason: 'already-off', status };
    }
    if (!status.owned) return { stopped: false, reason: 'not-owned', status };
    const session = await this.connect(this.native, status);
    let stopped = false;
    try {
      const after = await this.#stopOwnedWithSession(status);
      stopped = true;
      return { stopped: true, consent: session.consent, status: after };
    } finally {
      if (stopped) await session.release().catch(() => {});
      else await session.release();
    }
  }
  async restart({ resetExisting = false, restartService = false } = {}) {
    if (!resetExisting) throw new Error('F_RESET_AUTHORIZATION_REQUIRED');
    const status = await this.status();
    if (status.endpoint.listening) {
      if (!status.endpoint.verified) throw new Error('F_ENDPOINT_UNSAFE');
      if (!status.toolbarRunning) throw new Error('F_REMOTE_CONTROL_STATE_UNKNOWN');
      if (this.resetSession && !restartService) {
        await this.resetSession(this.native, status);
        this.completedStages.push('session-reset');
        const restarted = await this.start();
        return { ...restarted, resetExisting: true, sessionReset: true, serviceRestarted: false, mode: 'session-reset' };
      }
      // Explicit reset is the sole path allowed to stop a pre-existing/occupied
      // service. It deliberately does not acquire a session before stopping.
      await this.native.request('closeResetConsent');
      await this.native.request('power', { enabled: false, resetExisting: true });
      await this.#waitPower(false);
      this.completedStages.push('service-stopped');
      await this.store.clear();
    } else if (status.toolbarRunning) {
      throw new Error('F_REMOTE_CONTROL_INCONSISTENT');
    }
    const restarted = await this.start();
    if (!this.completedStages.includes('service-started')) this.completedStages.push('service-started');
    return { ...restarted, resetExisting: true, serviceRestarted: status.endpoint.listening, mode: 'service-restart' };
  }
  async reset({ resetExisting = false } = {}) {
    if (!resetExisting) throw new Error('F_RESET_AUTHORIZATION_REQUIRED');
    const status = await this.status();
    if (!status.endpoint.verified) throw new Error('F_ENDPOINT_UNSAFE');
    if (!this.resetSession) throw new Error('F_SESSION_RESET_UNAVAILABLE');
    const reset = await this.resetSession(this.native, status);
    this.completedStages.push('session-reset');
    return { sessionReset: true, sessionAlreadyClear: !!reset?.sessionAlreadyClear, serviceRestarted: false, status: await this.status() };
  }
  async run(task) {
    return this.#execute(task, () => new Error('F_TASK_FAILED'));
  }
  async install(artifact) {
    const { task: installation, ...lifecycle } = await this.#execute(async browser => {
      const result = await installPermanentAddon(browser, artifact, 10000, stage => this.completedStages.push(stage));
      if (result.status === 'active') this.completedStages.push('addon-installed');
      return result;
    }, error => error);
    return { ...lifecycle, installation };
  }
  async #execute(task, mapTaskError) {
    const running = await this.#ensureRunning();
    const session = await this.connect(this.native, running.status);
    let value;
    let taskFailure;
    let cleanupFailure;
    let stopped = false;
    try { value = await task(session.browser); }
    catch (error) { taskFailure = mapTaskError(error); }
    try {
      await this.native.request('assert');
      if (running.startedHere) {
        await this.#stopOwnedWithSession(running.status);
        stopped = true;
      }
    } catch (error) { cleanupFailure = error; }
    try { await session.release(); }
    catch (error) { if (!stopped) cleanupFailure ??= new Error('F_DISCONNECT_FAILED'); }
    if (cleanupFailure) throw cleanupFailure;
    if (taskFailure) throw taskFailure;
    return { task: value, startedHere: running.startedHere, stoppedHere: stopped, handshake: true, consent: session.consent, status: await this.status() };
  }
}
