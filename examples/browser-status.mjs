// Reads browser metadata only; no navigation, tab selection, or page contents.
export default async function browserStatus(browser) {
  return { version: await browser.version(), connected: browser.connected };
}
