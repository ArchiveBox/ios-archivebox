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
            document.documentElement.classList.add('archivebox-native-app');
            const monitor = document.getElementById('progress-monitor');
            if (monitor) {
                document.querySelectorAll('body style').forEach(style => document.head.append(style));
                const csrf = document.querySelector('input[name="csrfmiddlewaretoken"]');
                if (monitor.classList.contains('collapsed')) document.getElementById('progress-collapse')?.click();
                document.body.replaceChildren(monitor);
                if (csrf) document.body.append(csrf);
            }
            """#

    private static let navigationSource = #"""
            const isIOS = /iP(?:ad|hone|od)/.test(navigator.userAgent)
                || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
            document.documentElement.classList.add('archivebox-native-app');
            if (isIOS) {
                document.documentElement.classList.add('archivebox-ios-app');
                if (screen.width <= 600) document.documentElement.classList.add('archivebox-ios-phone');
            }
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
            }
            // Activity has its own standalone presentation above; the server owns
            // all app-specific CSS through the document marker classes.
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
            """#
}
