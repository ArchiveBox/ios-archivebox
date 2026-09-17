import AppKit
import ArchiveBoxCore
import WebKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSWindowDelegate, WKNavigationDelegate, NSMenuDelegate {
    enum Screen: String, CaseIterable { case archive = "Admin", activity = "Activity", shell = "Shell", users = "Users", settings = "Settings" }
    let runtime = Runtime()
    let browserAuthentication = BrowserAuthentication()
    var window: NSWindow!
    var web: WKWebView!
    var activity: WKWebView!
    var settingsView: NSHostingView<SettingsView>!
    var shellView: NSHostingView<ShellView>!
    var usersView: NSHostingView<UsersView>!
    var settings: SettingsModel!
    var tabs: NSSegmentedControl!
    var startup: Task<Void, Never>?
    var menuBarItem: NSStatusItem!
    var displayedAdmin: URL?
    var allowSetupShell = false
    var selectedScreen = Screen.settings
    var screens: [Screen] = [.settings]
    var menuStatus = NSMenuItem()
    var menuMetrics = NSMenuItem()
    var pauseItem = NSMenuItem()
    var menuRefresh: Task<Void, Never>?
    var lastMenuRefresh = Date.distantPast
    var crawlActivity: CrawlActivity?
    var menuError: String?
    var changingArchiving = false
    var renewingBrowserSession = false
    var lastRenewedLogin: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = SettingsModel(runtime: runtime)
        menuBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menuBarItem.button?.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "ArchiveBox Server")
        configureServerMenu()
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ArchiveBox Server", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Admin", action: #selector(showArchive), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Activity", action: #selector(showActivity), keyEquivalent: "2")
        viewMenu.addItem(withTitle: "Shell", action: #selector(showShell), keyEquivalent: "3")
        viewMenu.addItem(withTitle: "Users", action: #selector(showUsers), keyEquivalent: "4")
        viewMenu.addItem(withTitle: "Settings", action: #selector(showSettings), keyEquivalent: "5")
        viewMenu.addItem(withTitle: "Back", action: #selector(goBack), keyEquivalent: "[")
        viewMenu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "Open Data Folder", action: #selector(openData), keyEquivalent: "")
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 850),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ArchiveBox Server"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 760)
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "Navigation")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [.init("tabs")]
        window.toolbar = toolbar
        window.center()
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = browserAuthentication.dataStore
        web = WKWebView(frame: window.contentView!.bounds, configuration: webConfiguration)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        let activityConfiguration = WKWebViewConfiguration()
        activityConfiguration.websiteDataStore = web.configuration.websiteDataStore
        // The bundled server renders this component inside its admin page, not
        // at a standalone /live-progress/ route. Preserve the original component,
        // styles and polling code while removing the surrounding page chrome.
        activityConfiguration.userContentController.addUserScript(WKUserScript(source: #"""
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
        """#, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        activity = WKWebView(frame: web.frame, configuration: activityConfiguration)
        activity.autoresizingMask = [.width, .height]
        activity.navigationDelegate = self
        settingsView = NSHostingView(rootView: SettingsView(model: settings))
        shellView = NSHostingView(rootView: ShellView(model: settings))
        usersView = NSHostingView(rootView: UsersView(model: settings))
        settings.openAdmin = { [weak self] url in self?.openArchive(url) }
        settings.showCollectionShell = { [weak self] in
            guard let self else { return }
            allowSetupShell = true
            // A different collection can reuse the same admin hostname and user IDs.
            // Clear the old collection's browser session before opening the new one.
            web.load(URLRequest(url: URL(string: "about:blank")!))
            activity.load(URLRequest(url: URL(string: "about:blank")!))
            await web.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            displayedAdmin = nil
            screens = [.shell, .settings]
            tabs.segmentCount = screens.count
            for (index, screen) in screens.enumerated() { tabs.setLabel(screen.rawValue, forSegment: index); tabs.setWidth(0, forSegment: index) }
            tabs.sizeToFit()
            showShell()
        }
        settings.didUpdateDetails = { [weak self] details in
            guard let self else { return }
            do {
                if details.hasAdmin, let token = try runtime.browserAPIKey() {
                    try await browserAuthentication.authenticate(server: details.api, token: token)
                }
                if settings.restarting || displayedAdmin != details.admin || web.url?.path.contains("/login") == true {
                    web.load(URLRequest(url: details.admin))
                    if activity.url != nil { activity.load(URLRequest(url: details.admin)) }
                }
                displayedAdmin = details.admin
            } catch {
                settings.detail = "Could not sign in to the server: \(error.localizedDescription)"
            }
            screens = details.hasAdmin ? Screen.allCases : allowSetupShell ? [.shell, .settings] : [.settings]
            tabs.segmentCount = screens.count
            for (index, screen) in screens.enumerated() {
                tabs.setLabel(screen.rawValue, forSegment: index)
                tabs.setWidth(0, forSegment: index)
            }
            updateTabBadges(details)
            if !screens.contains(selectedScreen) { selectedScreen = .settings }
            tabs.selectedSegment = screens.firstIndex(of: selectedScreen) ?? 0
            if !details.hasAdmin { selectTab(selectedScreen) }
            if details.hasAdmin, web.url == nil { web.load(URLRequest(url: details.admin)) }
            viewMenu.items.filter { ["Admin", "Activity", "Shell", "Users"].contains($0.title) }.forEach { $0.isHidden = !details.hasAdmin }
        }
        window.contentView = settingsView
        selectTab(.settings)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startup = Task {
            do {
                try await Task.detached { [runtime] in
                    try await runtime.start { text in
                        Task { @MainActor in self.settings.detail = text }
                    }
                }.value
                settings.didStart()
            } catch {
                settings.didStart(error: error.localizedDescription)
            }
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("tabs"), .init("status"), .init("baseURL"), .init("metrics")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("tabs"), .flexibleSpace, .init("status"), .init("baseURL"), .init("metrics")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id.rawValue {
        case "status":
            item.view = NSHostingView(rootView: ServerToolbarStatus(model: settings))
            item.label = "Server status"
        case "baseURL":
            item.view = NSHostingView(rootView: ServerToolbarURL(model: settings))
            item.label = "Copy server URL"
        case "metrics":
            item.view = NSHostingView(rootView: ServerToolbarMetrics(model: settings))
            item.label = "CPU and RAM"
        default: break
        }
        if item.view != nil {
            // AppKit adds shared glass even around custom views; only the URL draws its own pill.
            item.isBordered = false
            return item
        }
        guard id.rawValue == "tabs" else { return nil }
        tabs = NSSegmentedControl(labels: ["Settings"], trackingMode: .selectOne, target: self, action: #selector(changeTab))
        tabs.segmentStyle = .automatic
        tabs.selectedSegment = 0
        tabs.setWidth(0, forSegment: 0)
        item.view = tabs
        item.label = "Screen"
        return item
    }

    func selectTab(_ screen: Screen) {
        selectedScreen = screens.contains(screen) ? screen : .settings
        tabs.selectedSegment = screens.firstIndex(of: selectedScreen) ?? 0
        let size = window.contentView!.frame.size
        let view: NSView
        switch selectedScreen {
        case .archive: view = web
        case .activity: view = activity
        case .shell: view = shellView
        case .users: view = usersView
        case .settings: view = settingsView
        }
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        // Toolbar metrics remain visible on every tab; closing the window stops polling.
        settings.monitor()
        if selectedScreen == .users { settings.refreshDetails() }
        if selectedScreen == .activity, let url = settings.serverDetails?.admin {
            activity.load(URLRequest(url: url))
        }
    }
    @objc func changeTab() { selectTab(screens[tabs.selectedSegment]) }
    @objc func showArchive() { selectTab(.archive); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showActivity() {
        selectTab(.activity)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showShell() { selectTab(.shell); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showUsers() { selectTab(.users); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showSettings() { selectTab(.settings); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func openArchive(_ url: URL) { guard settings.hasAdmin else { return }; showArchive(); web.load(URLRequest(url: url)) }
    @objc func goBack() { if selectedScreen == .archive { web.goBack() } }
    @objc func reload() { (selectedScreen == .activity ? activity : web)?.reload() }
    @objc func openData() { NSWorkspace.shared.open(runtime.collectionDirectory) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowWillClose(_ notification: Notification) { settings.pauseMonitoring() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if webView === activity, action.navigationType == .linkActivated, let url = action.request.url {
            openArchive(url); decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        if !url.path.contains("/login/") { lastRenewedLogin = nil; return }
        guard !renewingBrowserSession, lastRenewedLogin != url,
              let details = settings.serverDetails, details.hasAdmin else { return }
        renewingBrowserSession = true
        lastRenewedLogin = url
        Task {
            defer { renewingBrowserSession = false }
            do {
                guard let token = try runtime.browserAPIKey() else { return }
                try await browserAuthentication.authenticate(server: details.api, token: token, force: true)
                // Retry the intended admin page once after a server-side session expiry.
                let next = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "next" }?.value
                let destination = next.flatMap { URL(string: $0, relativeTo: details.admin)?.absoluteURL }
                webView.load(URLRequest(url: destination?.host == details.admin.host ? destination! : details.admin))
            } catch { settings.detail = "Could not renew browser login: \(error.localizedDescription)" }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        settings.shutdown()
        Task {
            await startup?.value
            await settings.finishHTTPChange()
            await settings.finishCollectionChange()
            await menuRefresh?.value
            await Task.detached { [runtime] in runtime.stop() }.value
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ArchiveBoxMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
