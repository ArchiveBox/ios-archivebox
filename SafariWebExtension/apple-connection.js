/* Packaging-only bridge. Upstream owns all extension behavior and settings UI. */
(() => {
  const panel = document.createElement('div');
  panel.style.cssText = 'display:flex;align-items:center;gap:8px;padding:10px 14px;font:13px system-ui;background:Canvas;color:CanvasText;border-bottom:1px solid GrayText;';
  const button = document.createElement('button');
  button.textContent = 'Use app connection';
  button.style.cssText = 'font:inherit;padding:6px 10px;cursor:pointer;';
  const status = document.createElement('span');
  status.setAttribute('role', 'status');
  status.textContent = 'Import the server and API key saved in the ArchiveBox app.';
  button.addEventListener('click', async () => {
    button.disabled = true;
    try {
      const response = await browser.runtime.sendNativeMessage('io.archivebox.ArchiveBox', { action: 'getConnection' });
      if (!response?.connection) throw new Error(response?.error || 'Test and save a connection in the ArchiveBox app first.');
      const { server, token } = response.connection;
      const url = new URL(server);
      if (!['http:', 'https:'].includes(url.protocol) || !token) throw new Error('The app returned an invalid connection.');
      await browser.storage.local.set({ archivebox_server_url: server, archivebox_api_key: token });
      // The existing WXT UI loads its settings at startup.
      location.reload();
    } catch (error) {
      status.textContent = error instanceof Error ? error.message : 'Could not import the app connection.';
      button.disabled = false;
    }
  });
  panel.append(button, status);
  document.body.prepend(panel);
})();
