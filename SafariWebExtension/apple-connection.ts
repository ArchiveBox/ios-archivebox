// Optional bridge for the bundled WXT build; standalone extension settings still work.
export async function appConnection(): Promise<{ server: string; token: string } | undefined> {
  try {
    const response = await browser.runtime.sendNativeMessage('io.archivebox.ArchiveBox', { action: 'getConnection' });
    const { server, token } = response?.connection || {};
    if (!['http:', 'https:'].includes(new URL(server).protocol) || !token) return;
    return { server, token };
  } catch {
    // No app connection (or a locked Keychain) must not block the options page.
    return;
  }
}
