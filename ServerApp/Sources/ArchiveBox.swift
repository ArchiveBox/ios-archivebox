import AppKit
import WebKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSWindowDelegate, WKNavigationDelegate, NSMenuDelegate {
    enum Screen: String, CaseIterable { case archive = "Archive", activity = "Activity", settings = "Settings" }
    let runtime = Runtime()
    var window: NSWindow!
    var web: WKWebView!
    var activity: WKWebView!
    var settingsView: NSHostingView<SettingsView>!
    var settings: SettingsModel!
    var tabs: NSSegmentedControl!
    var startup: Task<Void, Never>?
    var menuBarItem: NSStatusItem!
    var baseURLLabel: NSTextField?
    var displayedAdmin: URL?
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
        viewMenu.addItem(withTitle: "Archive", action: #selector(showArchive), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Settings", action: #selector(showSettings), keyEquivalent: "2")
        viewMenu.addItem(withTitle: "Activity", action: #selector(showActivity), keyEquivalent: "3")
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
        web = WKWebView(frame: window.contentView!.bounds)
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
        settings.openAdmin = { [weak self] url in self?.openArchive(url) }
        settings.didUpdateDetails = { [weak self] details in
            guard let self else { return }
            baseURLLabel?.attributedStringValue = NSAttributedString(string: details.base.absoluteString,
                attributes: [.link: details.base, .foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 12)])
            if settings.restarting || (displayedAdmin != nil && displayedAdmin != details.admin) {
                // A host/mode change needs fresh destinations, not a reload of the
                // old hostname. Do not move authenticated cookies across origins.
                web.load(URLRequest(url: details.admin))
                if activity.url != nil { activity.load(URLRequest(url: details.admin)) }
            }
            displayedAdmin = details.admin
            if let cookie = details.loginCookie {
                // Keep Django's admin session scoped to the exact admin host;
                // never share it with replay/API subdomains or persist a password.
                await web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
                web.load(URLRequest(url: details.admin))
            }
            screens = details.hasAdmin ? Screen.allCases : [.settings]
            tabs.segmentCount = screens.count
            for (index, screen) in screens.enumerated() {
                tabs.setLabel(screen.rawValue, forSegment: index)
                tabs.setWidth(115, forSegment: index)
            }
            tabs.sizeToFit()
            if !details.hasAdmin { selectedScreen = .settings }
            tabs.selectedSegment = screens.firstIndex(of: selectedScreen) ?? 0
            if !details.hasAdmin { selectTab(.settings) }
            if details.hasAdmin, web.url == nil { web.load(URLRequest(url: details.admin)) }
            for menu in [menuBarItem.menu, viewMenu] {
                menu?.items.filter { $0.title == "Archive" || $0.title == "Activity" }.forEach { $0.isHidden = !details.hasAdmin }
            }
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

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("tabs"), .init("baseURL")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("tabs"), .flexibleSpace, .init("baseURL")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id.rawValue == "baseURL" {
            let label = NSTextField(labelWithString: "")
            label.isSelectable = true; label.allowsEditingTextAttributes = true
            label.lineBreakMode = .byTruncatingMiddle
            label.setAccessibilityLabel("BASE_URL — open in default browser")
            label.widthAnchor.constraint(equalToConstant: 290).isActive = true
            baseURLLabel = label; item.view = label; item.label = "BASE_URL"
            item.toolTip = "Open in your default browser, or select and copy the address."
            return item
        }
        guard id.rawValue == "tabs" else { return nil }
        tabs = NSSegmentedControl(labels: ["Settings"], trackingMode: .selectOne, target: self, action: #selector(changeTab))
        tabs.segmentStyle = .automatic
        tabs.selectedSegment = 0
        tabs.setWidth(115, forSegment: 0)
        item.view = tabs
        item.label = "Screen"
        return item
    }

    func selectTab(_ screen: Screen) {
        selectedScreen = screens.contains(screen) ? screen : .settings
        tabs.selectedSegment = screens.firstIndex(of: selectedScreen) ?? 0
        let size = window.contentView!.frame.size
        let view: NSView = selectedScreen == .archive ? web : selectedScreen == .activity ? activity : settingsView
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        if selectedScreen == .settings { settings.monitor() } else { settings.pauseMonitoring() }
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
    @objc func showSettings() { selectTab(.settings); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func openArchive(_ url: URL) { guard settings.hasAdmin else { return }; showArchive(); web.load(URLRequest(url: url)) }
    @objc func goBack() { if selectedScreen == .archive { web.goBack() } }
    @objc func reload() { (selectedScreen == .activity ? activity : web)?.reload() }
    @objc func openData() { NSWorkspace.shared.open(runtime.home.appendingPathComponent("data")) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowWillClose(_ notification: Notification) { settings.pauseMonitoring() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            openArchive(url); decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if selectedScreen == .activity, let url = webView.url, url.path.contains("/login/") { openArchive(url) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        settings.shutdown()
        Task {
            await startup?.value
            await settings.finishHTTPChange()
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
