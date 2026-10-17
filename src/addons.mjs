const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

// Mozilla's documented vendor extension supplies the permanent flag and inventory
// missing from Puppeteer's high-level Firefox installation API. Never uninstall
// first: the regular same-ID update path preserves extension settings and data.
export async function findAddon(browser, id) {
  try {
    const { result } = await browser.connection.send('webExtension.moz:listExtensions', {});
    if (!Array.isArray(result.extensions)) throw new Error();
    const matches = result.extensions.filter(addon => addon.id === id);
    if (matches.length > 1) throw new Error();
    if (!matches.length) return null;
    const { name, version, isActive, temporarilyInstalled } = matches[0];
    return { id, name, version, isActive, temporarilyInstalled };
  } catch { throw new Error('F_ADDON_INVENTORY_UNAVAILABLE'); }
}

export async function installPermanentAddon(browser, artifact, timeoutMs = 10000, onStage = () => {}) {
  const previous = await findAddon(browser, artifact.id);
  async function submit() {
    let installedId;
    try {
      const { result } = await browser.connection.send('webExtension.install', {
        extensionData: { type: 'archivePath', path: artifact.path },
        'moz:permanent': true,
      });
      installedId = result.extension;
    } catch (error) {
      const message = String(error.message ?? '');
      if (/sign|certificate|verification/i.test(message)) throw new Error('F_ADDON_SIGNATURE_REQUIRED');
      if (/temporar/i.test(message)) throw new Error('F_TEMPORARY_ADDON_CONFLICT');
      throw new Error('F_ADDON_INSTALL_FAILED');
    }
    if (installedId !== artifact.id) throw new Error('F_ADDON_ID_MISMATCH');
  }
  await submit();
  onStage('addon-archive-installed');
  const receipt = { permanent: true, previous, artifact: { id: artifact.id, version: artifact.version, sha256: artifact.sha256 } };
  const deadline = Date.now() + timeoutMs;
  let replaceAfterEnable = previous?.temporarilyInstalled === false && previous.isActive === false && previous.version === artifact.version;
  let current;
  do {
    current = await findAddon(browser, artifact.id);
    if (current?.version === artifact.version && current.isActive === true && current.temporarilyInstalled === false) {
      // Firefox re-enables a disabled same-version copy without replacing its
      // files on the first request. Submit once more after that observed change.
      if (replaceAfterEnable) {
        replaceAfterEnable = false;
        await submit();
        continue;
      }
      return { ...receipt, status: 'active', addon: current };
    }
    // TemporaryLocation has higher precedence than app-profile. A successful
    // permanent install may remain underneath it until a normal browser restart.
    // Uninstalling the overlay emits onUninstalled and clears extension storage.
    // Keep both copies and report the activation boundary instead of uninstalling.
    if (previous?.temporarilyInstalled === true && current?.temporarilyInstalled === true) {
      return { ...receipt, status: 'restart-required', visibleAddon: current };
    }
    if (Date.now() >= deadline) break;
    await delay(250);
  } while (true);
  throw new Error(current?.temporarilyInstalled === true ? 'F_TEMPORARY_ADDON_CONFLICT' : 'F_ADDON_INSTALL_NOT_CONFIRMED');
}
