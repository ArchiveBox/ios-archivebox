// Bundled Safari only: Keychain remains the source of truth on every settings read.
// Never fall back to an old browser token if the app is unconfigured or locked.
export async function appConnection(): Promise<{ server: string; token: string }> {
  try {
    const response = await browser.runtime.sendNativeMessage('io.archivebox.ArchiveBox', { action: 'getConnection' });
    if (!response?.connection) throw new Error(response?.error || 'Test and save a connection in the ArchiveBox app first.');
    const { server, token } = response.connection;
    if (!['http:', 'https:'].includes(new URL(server).protocol) || !token) {
      throw new Error('The ArchiveBox app returned an invalid connection.');
    }
    if (typeof document !== 'undefined') document.getElementById('app-connection-status')?.remove();
    return { server, token };
  } catch (error) {
    // Startup callers do not all render rejected promises, so keep failures visible.
    if (typeof document !== 'undefined' && document.body) {
      let status = document.getElementById('app-connection-status');
      if (!status) {
        status = document.createElement('div');
        status.id = 'app-connection-status';
        status.setAttribute('role', 'alert');
        status.style.cssText = 'padding:12px;font:13px system-ui;background:Canvas;color:CanvasText;';
        document.body.prepend(status);
      }
      status.textContent = error instanceof Error ? error.message : 'Could not read the ArchiveBox app settings.';
    }
    throw error;
  }
}
