import WebKit

/// Shared presentation for native embedded pages. Server scripts still own polling
/// and navigation; these main-frame overrides only change the surrounding layout.
@MainActor public enum EmbeddedPage {
    public static func script(activity: Bool) -> WKUserScript {
        WKUserScript(source: activity ? activitySource : navigationSource,
                     injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    // The bundled server renders this component inside its admin page, not
    // at a standalone /live-progress/ route. Preserve the original component,
    // styles and polling code while removing the surrounding page chrome.
    private static let activitySource = #"""
            const monitor = document.getElementById('progress-monitor');
            if (monitor) {
                document.querySelectorAll('body style').forEach(style => document.head.append(style));
                const csrf = document.querySelector('input[name="csrfmiddlewaretoken"]');
                if (monitor.classList.contains('collapsed')) document.getElementById('progress-collapse')?.click();
                document.body.replaceChildren(monitor);
                if (csrf) document.body.append(csrf);
                const style = document.createElement('style');
                style.textContent = `html,body{margin:0!important;padding:0!important;background:#0d1117!important}
                    #progress-monitor{display:block!important;min-height:100vh}
                    #progress-monitor .progress-content{display:flex!important}
                    #progress-monitor .tree-container{max-height:calc(100vh - 80px)!important}
                    #progress-monitor .header-bar{pointer-events:none}
                    #progress-collapse{display:none!important}`;
                document.head.append(style);
            }
            """#

    private static let navigationSource = #"""
            const isIOS = /iP(?:ad|hone|od)/.test(navigator.userAgent)
                || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
            // Move the existing breadcrumb nodes to retain their links and labels.
            // Keep one header while preserving the server's mobile stacking.
            const header = document.querySelector('#header');
            if (header?.querySelector('#branding img')) {
                let crumbs = document.querySelector('.breadcrumbs');
                if (!crumbs) {
                    crumbs = document.createElement('nav');
                    crumbs.className = 'breadcrumbs';
                    const label = document.querySelector('.add-page') ? 'Add URLs'
                        : /\/snapshot\/grid\/?$/.test(location.pathname) ? 'Snapshots'
                        : document.querySelector('body.opencode-agent') ? 'AI Agent'
                        : document.querySelector('#content h1')?.textContent.trim()
                            || document.title.split('|')[0].trim() || 'ArchiveBox';
                    const home = document.createElement('a');
                    home.href = '/admin/';
                    home.textContent = 'Home';
                    crumbs.append(home, document.createTextNode(` › ${label}`));
                }
                if (crumbs) {
                    crumbs.setAttribute('aria-label', 'Breadcrumbs');
                    header.append(crumbs);
                }
                header.classList.add('archivebox-app-header');
                const style = document.createElement('style');
                style.textContent = `
                    #header.archivebox-app-header {
                        display:flex!important; align-items:center!important; gap:12px!important;
                        box-sizing:border-box; width:100%; min-width:0; height:auto!important;
                        min-height:44px; padding:8px 12px!important; flex-shrink:0;
                        background:#a51c50!important; color:#fff!important;
                        font:500 13px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;
                    }
                    #header.archivebox-app-header > :not(#branding):not(.breadcrumbs),
                    #header.archivebox-app-header .branding-label,
                    #progress-monitor { display:none!important; }
                    #header.archivebox-app-header #branding { flex:0 0 auto; margin:0!important; padding:0!important; }
                    #header.archivebox-app-header #site-name { margin:0!important; padding:0!important; line-height:1!important; }
                    #header.archivebox-app-header #branding a { display:flex; align-items:center; }
                    #header.archivebox-app-header #branding img { width:26px!important; height:26px!important; margin:0!important; object-fit:contain; }
                    #header.archivebox-app-header .breadcrumbs {
                        display:block!important; visibility:visible!important; opacity:1!important;
                        flex:1 1 0; min-width:0; margin:0!important; padding:0!important;
                        background:transparent!important; color:#fff!important;
                        font:inherit!important; white-space:normal!important; overflow-wrap:anywhere;
                    }
                    #header.archivebox-app-header .breadcrumbs a {
                        color:#fff!important; font:inherit!important; text-decoration:none;
                        text-underline-offset:3px;
                    }
                    #header.archivebox-app-header .breadcrumbs a:hover { text-decoration:underline; }
                    #header.archivebox-app-header a:focus-visible { outline:2px solid white; outline-offset:3px; }
                `;
                document.head.append(style);
            }
            if (isIOS) {
                // Leave room for the native menu button inside the web header.
                const style = document.createElement('style');
                style.textContent = `
                    #header.archivebox-app-header {
                        box-sizing:border-box; min-height:60px; padding-left:64px!important;
                    }
                    header:has(> .header-top), .header-top { background:#a51c50!important; }
                    .header-top { padding-left:8px!important; padding-right:8px!important; }
                    /* Reserve Back's hit area in the logo row, not every header row. */
                    .header-top .header-left {
                        box-sizing:border-box; padding-left:52px; min-height:48px;
                        display:flex; align-items:center;
                    }
                    @container snapshot-header (max-width:480px) {
                        .header-top .header-nav { grid-template-columns:74px minmax(0,1fr); }
                        .header-top .header-url { align-self:center; }
                    }
                    @media (max-width:520px) {
                        #header.archivebox-app-header { padding-right:64px!important; }
                    }
                `;
                document.head.append(style);
            }
            if (document.querySelector('.header-title-line')) {
                const style = document.createElement('style');
                style.textContent = `
                    .header-title-line .header-title-text { min-width:0; flex:1 1 0; }
                    .header-title-line .favicon { flex-shrink:0; }
                    .header-archivebox { white-space:nowrap; }
                `;
                document.head.append(style);
            }
            // Keep all embedded-page presentation overrides in this main-frame script.
            // Activity has its own standalone layout above.
            const agent = document.querySelector('body.opencode-agent #content-main');
            if (agent) {
                // The server subtracts a fixed 150px header; compact embedded headers
                // differ. Measure the real space, including after wrapping/resizing.
                const fit = () => {
                    agent.style.minHeight = '0';
                    agent.style.height = `${Math.max(0, innerHeight - agent.getBoundingClientRect().top)}px`;
                };
                fit();
                window.addEventListener('resize', fit);
                const headers = new ResizeObserver(fit);
                document.querySelectorAll('#header, .breadcrumbs, #archivebox-live-status').forEach(e => headers.observe(e));
            }
            // Add omits Django's responsive stylesheet, leaving a desktop minimum width.
            if (document.querySelector('.add-page')) {
                const base = document.querySelector('link[href*="admin/css/base.css"]');
                if (base && !document.querySelector('link[href*="admin/css/responsive.css"]')) {
                    const responsive = document.createElement('link');
                    responsive.rel = 'stylesheet';
                    responsive.href = base.href.replace('admin/css/base.css', 'admin/css/responsive.css');
                    // Keep ArchiveBox’s navbar overrides after Django’s responsive defaults.
                    base.after(responsive);
                }
                const style = document.createElement('style');
                // Native Add URLs already provides sharing/extension help; hide
                // the server's shortcut banner together with its empty wrapper.
                style.textContent = `#container { min-width: 0; width: 100%; }
                    #content { min-width: 0; max-width: 100%; box-sizing: border-box; }
                    .add-page .crawl-explanation:has(.crawl-tip) { display: none !important; }
                    `;
                document.head.append(style);
            }
            """#
}
