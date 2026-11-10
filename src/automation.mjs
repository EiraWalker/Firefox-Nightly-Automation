import { ownsService } from './state.mjs';
import { installPermanentAddon, verifyInstalledAddon } from './addons.mjs';
import { requestProtocolStop } from './service-stop.mjs';

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const defaultWorkspace = async (...args) => (await import('./workspace.mjs')).createTaskWorkspace(...args);

export class NightlyAutomation {
  constructor({ native, store, connect, resetSession, createWorkspace = defaultWorkspace }) {
    this.native = native; this.store = store; this.connect = connect; this.resetSession = resetSession;
    this.createWorkspace = createWorkspace;
    this.completedStages = [];
  }
  async status() {
    const status = await this.native.request('status');
    return { ...status, owned: ownsService(await this.store.read(), status) };
  }
  async #connectSession(status) {
    const session = await this.connect(this.native, status);
    let releasing;
    // Early shutdown and outer finally paths share one disconnect/session.end.
    return { ...session, release: () => releasing ??= Promise.resolve().then(() => session.release()) };
  }
  async #releaseSession(session, failure, confirmedStopped = false) {
    try { await session.release(); }
    catch {
      if (failure) {
        if (typeof failure === 'object' && Object.isExtensible(failure)) failure.cleanupError ??= 'F_DISCONNECT_FAILED';
      } else if (!confirmedStopped) throw new Error('F_DISCONNECT_FAILED');
    }
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
      if (after?.toolbarAvailable && !after.endpoint.listening && !after.toolbarRunning) {
        if (previous) await this.store.write(previous); else await this.store.clear();
      }
      throw error;
    }
  }
  async #waitPower(enabled, allowStartPreparation = false) {
    const deadline = Date.now() + (allowStartPreparation ? 90000 : 10000);
    let prepared = false;
    do {
      const status = await this.native.request('status');
      await this.native.request('assert');
      if (!status.toolbarAvailable) throw new Error('F_REMOTE_CONTROL_STATE_UNKNOWN');
      if (enabled && status.endpoint.verified && status.toolbarRunning) return status;
      if (!enabled && !status.endpoint.listening && !status.toolbarRunning) return status;
      if (!enabled && allowStartPreparation && !prepared && !status.endpoint.listening && status.toolbarRunning && status.window?.minimized === true) {
        // Minimized chrome can retain its old label after protocol shutdown.
        // Use authorized START preparation once, never stop/enable again.
        prepared = true;
        await this.native.request('power', { enabled: true, prepareOnly: true, restartAuthorized: true });
      }
      await delay(200);
    } while (Date.now() < deadline);
    throw new Error('F_POWER_NOT_CONFIRMED');
  }
  async #stopWithSession(status, browser, { restartAuthorized = false, release } = {}) {
    const expected = { phase: 'running', browser: status.browser, port: status.port, endpointCreated: status.endpoint.created };
    const assertOwned = async () => {
      await this.native.request('assert');
      const current = await this.status();
      // Explicit restart authorizes this exact borrowed generation, never a
      // durable ownership claim. Ordinary stop/run still require the record.
      if (!current.endpoint.verified || !current.toolbarRunning || (!restartAuthorized && !ownsService(await this.store.read(), current)) || !ownsService(expected, current)) throw new Error('F_OWNERSHIP_CHANGED');
      if ((restartAuthorized && browser?.connected !== true) || browser?.connected === false || (typeof browser?.isConnected === 'function' && !browser.isConnected())) throw new Error('F_SESSION_LOST');
    };
    await assertOwned();
    // The owned BiDi session remains connected until the stop command executes.
    // Firefox permits only one active WebDriver session, so this cannot disconnect another one.
    if (!await requestProtocolStop(browser, assertOwned)) {
      // Capability checks can outlive a service/session. Revalidate the original
      // generation immediately before any native fallback, not just on entry.
      await assertOwned();
      await this.native.request('power', { enabled: false, expectedService: expected });
    }
    // The owned stop is already dispatched. Release only its client before
    // readback: Firefox can otherwise wait on this very connection to stop.
    // A lost socket is still not success; confirm toolbar and listener below.
    if (release) await release().catch(() => {});
    const stopped = await this.#waitPower(false, restartAuthorized);
    if (ownsService(await this.store.read(), status)) await this.store.clear();
    return stopped;
  }
  async start({ denyPendingConsent = false } = {}) {
    const pendingConsent = denyPendingConsent ? await this.native.request('denyPendingConsent') : undefined;
    const running = await this.#ensureRunning();
    const session = await this.#connectSession(running.status);
    let failure;
    try {
      return { startedHere: running.startedHere, owned: running.status.owned, handshake: true, consent: session.consent, status: await this.status(), ...(pendingConsent ? { pendingConsent } : {}) };
    } catch (error) { failure = error; throw error; }
    finally { await this.#releaseSession(session, failure); }
  }
  async stop() {
    const status = await this.status();
    if (!status.endpoint.listening) {
      if (status.owned) await this.store.clear();
      return { stopped: false, reason: 'already-off', status };
    }
    if (!status.owned) return { stopped: false, reason: 'not-owned', status };
    const session = await this.#connectSession(status);
    let stopped = false;
    let failure;
    try {
      const after = await this.#stopWithSession(status, session.browser, { release: session.release });
      stopped = true;
      return { stopped: true, consent: session.consent, status: after };
    } catch (error) { failure = error; throw error; }
    finally { await this.#releaseSession(session, failure, stopped); }
  }
  async restart({ resetExisting = false, restartService = false } = {}) {
    if (!resetExisting) throw new Error('F_RESET_AUTHORIZATION_REQUIRED');
    const status = await this.status();
    if (status.endpoint.listening) {
      if (!status.endpoint.verified) throw new Error('F_ENDPOINT_UNSAFE');
      if (!status.toolbarRunning) throw new Error('F_REMOTE_CONTROL_STATE_UNKNOWN');
      if (this.resetSession) {
        await this.resetSession(this.native, status);
        this.completedStages.push('session-reset');
        if (!restartService) {
          const restarted = await this.start();
          return { ...restarted, resetExisting: true, sessionReset: true, serviceRestarted: false, mode: 'session-reset' };
        }
        const session = await this.#connectSession(status);
        try {
          await this.#stopWithSession(status, session.browser, { restartAuthorized: true, release: session.release });
          this.completedStages.push('service-stopped');
        } finally {
          // Server stop may have closed this socket. Do not mask the original
          // stop/readback failure or retry the command if release also fails.
          await session.release().catch(() => {});
        }
      } else {
        if (!restartService) throw new Error('F_SESSION_RESET_UNAVAILABLE');
        // Legacy adapters without session reset retain the guarded native path.
        await this.native.request('closeResetConsent');
        await this.native.request('power', { enabled: false, resetExisting: true });
        await this.#waitPower(false);
        this.completedStages.push('service-stopped');
        if (ownsService(await this.store.read(), status)) await this.store.clear();
      }
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
  async run(task, options) {
    await this.native.request('enableWorkspaceGuard');
    return this.#execute(task, error => /^F_WORKSPACE_[A-Z_]+$/.test(error?.message) ? new Error(error.message) : new Error('F_TASK_FAILED'), options, true);
  }
  async install(artifact, options) {
    try {
      const { task: installation, ...lifecycle } = await this.#execute(async browser => {
        const result = await installPermanentAddon(browser, artifact, 10000, stage => this.completedStages.push(stage));
        if (result.status === 'active') this.completedStages.push('addon-installed');
        return result;
      }, error => error, options);
      return { ...lifecycle, installation };
    } catch (error) {
      if (error.data && 'task' in error.data) {
        const { task: installation, ...lifecycle } = error.data;
        error.data = { ...lifecycle, installation };
      }
      error.data ??= {};
      error.data.installation ??= { permanent: true, status: 'not-started', archiveInstalled: false, artifact: { id: artifact.id, version: artifact.version, sha256: artifact.sha256 } };
      throw error;
    }
  }
  async verify(target) {
    try {
      const { task: installation, ...lifecycle } = await this.#execute(browser => verifyInstalledAddon(browser, target), error => error);
      return { ...lifecycle, installation };
    } catch (error) {
      if (error.data && 'task' in error.data) {
        const { task: installation, ...lifecycle } = error.data;
        error.data = { ...lifecycle, installation };
      }
      error.data ??= {};
      error.data.installation ??= { readOnly: true, status: 'not-started', installedHashVerified: false, artifact: { id: target.id, version: target.version, sha256: target.sha256 } };
      throw error;
    }
  }
  async #execute(task, mapTaskError, { denyPendingConsent = false, allowWorkspaceCreationActivation = true } = {}, isolated = false) {
    const pendingConsent = denyPendingConsent ? await this.native.request('denyPendingConsent') : undefined;
    const running = await this.#ensureRunning();
    const session = await this.#connectSession(running.status);
    let value;
    let taskFailure;
    let cleanupFailure;
    const cleanupErrors = [];
    const recordCleanup = (stage, error) => {
      cleanupFailure ??= error;
      cleanupErrors.push({ stage, code: /^F_[A-Z_]+$/.test(error?.message) ? error.message : 'F_OPERATION_FAILED' });
    };
    let stopped = false;
    let workspace;
    let workspaceClosed = false;
    let taskInvoked = false;
    try {
      if (isolated) {
        const created = await this.createWorkspace(session.browser, this.native, { allowCreationActivation: allowWorkspaceCreationActivation });
        if (!created?.browser || !created.page || typeof created.assert !== 'function' || typeof created.close !== 'function') throw new Error('F_WORKSPACE_NOT_CREATED');
        workspace = created;
        this.completedStages.push('workspace-created');
      }
      const taskWorkspace = workspace ? Object.freeze({ page: workspace.page, info: Object.freeze({ ...workspace.info }) }) : undefined;
      taskInvoked = true;
      value = await task(workspace?.browser ?? session.browser, taskWorkspace);
    }
    catch (error) {
      taskFailure = isolated && !taskInvoked ? new Error(/^F_[A-Z_]+$/.test(error?.message) ? error.message : 'F_WORKSPACE_CREATE_FAILED') : mapTaskError(error);
      if (isolated && !workspace && error.cleanupError) {
        recordCleanup('workspace-create-recovery', new Error(/^F_[A-Z_]+$/.test(error.cleanupError) ? error.cleanupError : 'F_WORKSPACE_CLOSE_FAILED'));
      }
    }
    if (workspace) {
      try { await workspace.assert(); }
      catch (error) { recordCleanup('workspace-assert', error); }
      try {
        await workspace.close();
        workspaceClosed = true;
        this.completedStages.push('workspace-closed');
      } catch (error) { recordCleanup('workspace-close', error); }
    }
    let cleanupStage = 'desktop-assert';
    try {
      await this.native.request('assert');
      if (running.startedHere && (!workspace || workspaceClosed)) {
        cleanupStage = 'service-stop';
        await this.#stopWithSession(running.status, session.browser, { release: session.release });
        stopped = true;
      }
    } catch (error) { recordCleanup(cleanupStage, error); }
    try { await session.release(); }
    catch { if (!stopped) recordCleanup('session-release', new Error('F_DISCONNECT_FAILED')); }
    const data = { startedHere: running.startedHere, stoppedHere: stopped, handshake: true, consent: session.consent, ...(pendingConsent ? { pendingConsent } : {}) };
    if (workspace) data.workspace = { ...workspace.info, closed: workspaceClosed };
    if (!taskFailure) data.task = value;
    if (taskFailure?.installation) data.installation = taskFailure.installation;
    if (!cleanupFailure && !taskFailure) {
      try { data.status = await this.status(); }
      catch (error) { recordCleanup('status-readback', error); }
    }
    // Preserve the observed task result without turning failed cleanup into success.
    // Cleanup keeps its historical precedence; both coded failures remain visible.
    const failure = cleanupFailure ?? taskFailure;
    if (failure) {
      failure.data = data;
      if (taskFailure) failure.taskError = /^F_[A-Z_]+$/.test(taskFailure.message) ? taskFailure.message : 'F_OPERATION_FAILED';
      if (cleanupFailure) failure.cleanupError = /^F_[A-Z_]+$/.test(cleanupFailure.message) ? cleanupFailure.message : 'F_OPERATION_FAILED';
      if (cleanupErrors.length) failure.cleanupErrors = cleanupErrors;
      throw failure;
    }
    return data;
  }
}
