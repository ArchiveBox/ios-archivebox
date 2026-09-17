import SafariServices
import SwiftUI
import WebKit
import ArchiveBoxCore

struct MainView: View {
    @Environment(\.openURL) private var openURL
    @Bindable var settings: SettingsModel
    var settingsNavigationID: UUID? = nil
    @State private var selection: Screen? = .settings
    @State private var pages = WebPages()
    @State private var reloadIDs: [Screen: UUID] = [:]
    @State private var compactColumn: NavigationSplitViewColumn = .detail
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    private enum Screen: String, CaseIterable {
        case add, agent, activity, crawls, schedules, snapshots, results, tags, admin, users, personas, keys, webhooks
        case processes, machines, interfaces, binaries, plugins, workers, logs, github, docs, bugs, forum, extensionSource, settings

        var info: (title: String, icon: String, path: String) {
            switch self {
            case .add: ("Add URLs", "plus", "add/")
            case .agent: ("AI Agent", "sparkles", "admin/agent/")
            case .activity: ("Activity", "arrow.down.circle", "admin/")
            case .crawls: ("Crawls", "point.3.connected.trianglepath.dotted", "admin/crawls/crawl/")
            case .schedules: ("Scheduled Crawls", "calendar.badge.clock", "admin/crawls/crawlschedule/")
            case .snapshots: ("Snapshots", "building.columns", "admin/core/snapshot/grid/")
            case .results: ("Archive Results", "doc.richtext", "admin/core/archiveresult/")
            case .tags: ("Tags", "tag", "admin/core/tag/")
            case .admin: ("Admin", "person.crop.circle", "admin/")
            case .users: ("Users", "person.2", "admin/auth/user/")
            case .personas: ("Personas", "person.crop.rectangle.stack", "admin/personas/persona/")
            case .keys: ("API Keys", "key", "admin/api/apitoken/")
            case .webhooks: ("Webhooks", "arrow.triangle.branch", "admin/api/outboundwebhook/")
            case .processes: ("Processes", "cpu", "admin/machine/process/")
            case .machines: ("Machines", "desktopcomputer", "admin/machine/machine/")
            case .interfaces: ("Network Interfaces", "network", "admin/machine/networkinterface/")
            case .binaries: ("Binaries", "terminal", "admin/machine/binary/")
            case .plugins: ("Plugins", "puzzlepiece.extension", "admin/environment/plugins/")
            case .workers: ("Workers", "gearshape.2", "admin/environment/workers/")
            case .logs: ("Logs", "doc.text", "admin/environment/logs/")
            case .github: ("GitHub", "chevron.left.forwardslash.chevron.right", "https://github.com/ArchiveBox")
            case .docs: ("ArchiveBox Docs", "book", "https://github.com/ArchiveBox/ArchiveBox/wiki")
            case .bugs: ("Bug Reports", "ladybug", "https://github.com/ArchiveBox/ios-archivebox/issues")
            case .forum: ("Forum", "bubble.left.and.bubble.right", "https://zulip.archivebox.io")
            case .extensionSource: ("Browser Extension", "puzzlepiece.extension", "https://github.com/ArchiveBox/archivebox-browser-extension")
            case .settings: ("Connection Settings", "gearshape", "")
            }
        }
        var isHelp: Bool { info.path.hasPrefix("https://") }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            List {
                rows([.add, .agent])
                Section("Collection") { rows([.crawls, .schedules, .snapshots, .results, .tags]) }
                Section {
                    rows([.users, .personas, .keys, .webhooks, .processes, .machines, .interfaces, .binaries, .plugins, .workers, .logs])
                } header: {
                    Button { activate(.admin) } label: {
                        HStack { Text("Admin"); Image(systemName: "arrow.up.right").imageScale(.small) }
                    }
                    .buttonStyle(.plain).disabled(settings.verifiedServer == nil)
                    .accessibilityLabel("Admin home").accessibilityIdentifier("sidebar.admin")
                }
                Section("Help") { rows([.github, .docs, .bugs, .forum, .extensionSource]) }
                Section { rows([.settings]) }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarSummary(settings: settings, sidebarVisible: columnVisibility != .detailOnly) { activate(.activity) }
            }
            .navigationTitle("ArchiveBox")
            #if os(iOS)
            // Split-view sidebars can ignore navigation-bar backgrounds. Own the
            // header's backdrop so branding stays readable in every size class.
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    Image("BrandLogo")
                        .resizable().scaledToFit().frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                    Text("ArchiveBox").font(.headline.weight(.semibold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.accentColor.ignoresSafeArea(edges: .top))
                .accessibilityAddTraits(.isHeader)
            }
            #endif
            #if os(macOS)
            .toolbar {
                if selection == nil || selection == .settings {
                ToolbarItem(placement: .navigation) {
                    Image("BrandLogo")
                        .resizable().scaledToFit().frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("ArchiveBox")
                }
                .sharedBackgroundVisibility(.hidden)
                }
            }
            #endif
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            let screen = selection ?? .settings
            Group {
                if screen == .settings { SettingsView(model: settings) }
                else {
                    Group {
                        if screen == .add { AddURLsView(model: settings, pages: pages, reloadID: reloadIDs[.add]) }
                        else if let url = destination(screen) {
                            ServerWebView(url: url, title: screen.info.title, session: pages.page(for: "\(screen.rawValue)-\(url)"),
                                          reloadID: screen == .admin ? settings.adminNavigationID : reloadIDs[screen])
                                .id("\(screen.rawValue)-\(url)")
                        } else {
                            ContentUnavailableView("Connect your server", systemImage: "network", description: Text("Choose Connection Settings to get started."))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if os(macOS)
                    // Apply at the detail column: a child WebView cannot fill the
                    // titlebar or bottom inset reserved by its navigation container.
                    .toolbar(removing: .title)
                    .ignoresSafeArea(.container, edges: .vertical)
                    #endif
                }
            }
            #if os(iOS)
            .navigationTitle(screen.info.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            #endif
        }
        #if os(macOS)
        // Hiding the window toolbar also removes traffic lights. Keep its controls,
        // but let web content fill the transparent titlebar in the detail column.
        .toolbarBackgroundVisibility(selection == nil || selection == .settings ? .automatic : .hidden, for: .windowToolbar)
        #endif
        .task { settings.load() }
        .task(id: "\(settings.verifiedServer?.absoluteString ?? "")\n\(settings.verifiedToken ?? "")") {
            await pages.configure(server: settings.verifiedServer, token: settings.verifiedToken)
        }
        .onChange(of: settingsNavigationID) {
            selection = .settings
            compactColumn = .detail
        }
        .onChange(of: settings.adminNavigationID) {
            selection = .admin
            compactColumn = .detail
        }
        .onChange(of: settings.verifiedServer) {
            if settings.verifiedServer == nil, let selection, !selection.isHelp, selection != .add { self.selection = .settings }
        }
    }

    @ViewBuilder private func rows(_ screens: [Screen]) -> some View {
        ForEach(screens, id: \.self) { screen in
            Button { activate(screen) } label: {
                Label(screen.info.title, systemImage: screen.info.icon)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .listRowBackground(selection == screen ? Color.accentColor.opacity(0.18) : Color.clear)
                .accessibilityAddTraits(selection == screen ? .isSelected : [])
                .accessibilityIdentifier("sidebar.\(screen.rawValue)")
                .disabled(screen != .add && screen != .settings && !screen.isHelp && settings.verifiedServer == nil)
        }
    }

    private func activate(_ screen: Screen) {
        if screen.isHelp, let url = URL(string: screen.info.path) { openURL(url); return }
        // Only an explicit repeat click resets the page. Switching away and back
        // retains the cached page, including its current URL and form contents.
        if selection == screen {
            if screen == .admin { settings.openAdmin(settings.adminURL) }
            else { reloadIDs[screen] = UUID() }
        }
        selection = screen
        compactColumn = .detail
    }

    private func destination(_ screen: Screen) -> URL? {
        if screen.isHelp { return nil }
        if screen == .admin, let target = settings.adminDestination { return target }
        return settings.verifiedServer?.appending(path: screen.info.path)
    }
}

private struct SidebarSummary: View {
    let settings: SettingsModel
    let sidebarVisible: Bool
    let openActivity: () -> Void
    @State private var hoveringActivity = false
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif
    @State private var appeared = false
    @State private var progress: SidebarProgress?
    @State private var latency: Int?
    @State private var connected: Bool?
    @State private var failure: String?
    @State private var loginKey = ""
    @State private var lastRequest = Date.distantPast
    @State private var client = ArchiveBoxClient()

    private var credentials: String {
        "\(settings.verifiedServer?.absoluteString ?? "")\n\(settings.verifiedToken ?? "")"
    }
    private var polling: Bool {
        #if os(macOS)
        appeared && sidebarVisible && scenePhase == .active && controlActiveState != .inactive
        #else
        appeared && sidebarVisible && scenePhase == .active
        #endif
    }

    var body: some View {
        Button(action: openActivity) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle").frame(width: 16, alignment: .leading)
                    Text(progress.map { "\($0.crawls_active) active crawls" } ?? "Activity unavailable")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .foregroundStyle(hoveringActivity ? Color.accentColor : Color.primary)
                if let crawl = progress?.active_crawls.sorted(by: {
                    if ($0.status == "started") != ($1.status == "started") { return $0.status == "started" }
                    return ($0.started ?? "") > ($1.started ?? "")
                }).first {
                    Text(crawl.label).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).padding(.leading, 22)
                }
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive").frame(width: 16, alignment: .leading)
                    Text(progress?.collection.map {
                        "\($0.snapshots) snapshots · \(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file))"
                    } ?? "Collection size unavailable")
                }
                HStack(spacing: 6) {
                    Circle().fill(connected == nil ? Color.secondary : connected == true ? .green : .red).frame(width: 7, height: 7).padding(.leading, 3).frame(width: 16, alignment: .leading)
                    Text(connected == nil ? "Not checked" : connected == true ? "Connected" : "Unavailable")
                    Spacer(minLength: 0)
                    if let latency { Text("\(latency) ms").foregroundStyle(.secondary) }
                }
            }
            .font(.caption).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color("SidebarStatusBackground").ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) {
                Rectangle().fill(.primary.opacity(0.12)).frame(height: 2)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine).accessibilityIdentifier("sidebar.summary")
        }
        .buttonStyle(.plain)
        .disabled(settings.verifiedServer == nil)
        .onHover { hoveringActivity = $0 }
        .help(failure ?? "Open live progress. Updates every five seconds while this sidebar is active. Collection size is based on stored archive files.")
        .accessibilityHint("Open live progress")
        .accessibilityIdentifier("sidebar.openActivity")
        .onAppear { appeared = true }.onDisappear { appeared = false }
        .task(id: "\(polling)-\(credentials)") {
            if loginKey != credentials {
                progress = nil; connected = nil; latency = nil
                loginKey = credentials
            }
            guard polling, let server = settings.verifiedServer else { return }
            // A single cancellable loop avoids overlapping requests. Keep the last
            // request time across focus changes so toggling windows cannot burst-poll.
            while !Task.isCancelled {
                do {
                    let delay = max(0, 5 - Date().timeIntervalSince(lastRequest))
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    try Task.checkCancellation()
                    lastRequest = Date()
                    // Reuse the admin webview's login, including on servers that
                    // predate API-key-to-browser-session exchange. Never send cookies
                    // to another configured server or through an HTTP redirect.
                    let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                    let host = server.host() ?? ""
                    let root = host.hasPrefix("api.") ? String(host.dropFirst(4)) : host
                    guard let session = cookies.first(where: {
                        $0.name.hasPrefix("archivebox_sessionid_") && $0.domain == "admin.\(root)"
                    }) ?? cookies.first(where: {
                        $0.name.hasPrefix("archivebox_sessionid_") && ($0.domain == host || $0.domain == ".\(root)")
                    }) else { throw ArchiveBoxError.message("Open Admin and sign in to see collection activity.") }
                    var address = URLComponents(url: server, resolvingAgainstBaseURL: false)!
                    address.host = session.domain.hasPrefix(".") ? "admin.\(root)" : session.domain
                    address.path = "/"; address.query = nil; address.fragment = nil
                    guard let origin = address.url, !session.isSecure || origin.scheme == "https" else {
                        throw ArchiveBoxError.message("The admin session requires HTTPS.")
                    }
                    let start = ContinuousClock.now
                    let value = try await client.sidebarProgress(server: origin, cookie: "\(session.name)=\(session.value)")
                    try Task.checkCancellation()
                    let elapsed = start.duration(to: .now).components
                    latency = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
                    progress = value; connected = true; failure = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    connected = false; failure = error.localizedDescription
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}

// Embedded pages share an in-memory cookie store; the Keychain API key restores
// the session after relaunch without persisting browser credentials.
@MainActor @Observable private final class PageSession {
    let page: WebPage
    var errorMessage: String?
    private var started = false
    private var requestID: UUID?
    private var navigation: Task<Void, Never>?
    private unowned let owner: WebPages
    private var destination: URL?
    init(_ page: WebPage, owner: WebPages) { self.page = page; self.owner = owner }

    func reconnect() {
        if let destination { load(destination, requestID: requestID, force: true) }
    }

    func load(_ url: URL, requestID: UUID?, force: Bool = false) {
        guard force || !started || self.requestID != requestID else { return }
        destination = url
        started = true
        self.requestID = requestID
        navigation?.cancel()
        errorMessage = nil
        // Navigation belongs to the cached page, not a transient SwiftUI view.
        // Sidebar transitions must not cancel a load and leave a blank cached page.
        navigation = Task {
            do {
                try await owner.authenticate()
                for try await _ in page.load(url) {}
                // An expired/deleted server session can redirect to login even before
                // its advertised expiry. Exchange the key once, never loop on failure.
                if page.url?.path.contains("/login") == true, owner.hasCredentials {
                    try await owner.authenticate(force: true)
                    for try await _ in page.load(url) {}
                }
            }
            catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
}

@MainActor private final class WebPages {
    private var pages: [String: PageSession] = [:]
    let authentication = BrowserAuthentication()
    private var server: URL?
    private var token: String?
    var hasCredentials: Bool { server != nil && token != nil }

    func configure(server: URL?, token: String?) async {
        guard self.server != server || self.token != token else { return }
        self.server = server; self.token = token
        if server == nil || token == nil { await authentication.clear() }
        for page in pages.values { page.reconnect() }
    }

    func authenticate(force: Bool = false) async throws {
        guard let server, let token else { return }
        try await authentication.authenticate(server: server, token: token, force: force)
    }

    // Retain each screen's page independently, but allocate it only when visited.
    // All pages share the same authenticated in-memory cookie store.
    func page(for key: String) -> PageSession {
        if let page = pages[key] { return page }
        var configuration = WebPage.Configuration()
        // Match the companion's standalone monitor without stripping the admin
        // chrome from other screens or altering its server-owned polling code.
        if key.hasPrefix("activity-") {
            configuration.userContentController.addUserScript(WKUserScript(source: #"""
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
        }
        configuration.websiteDataStore = authentication.dataStore
        if !key.hasPrefix("activity-") {
            configuration.userContentController.addUserScript(WKUserScript(source: #"""
            // Move the existing breadcrumb nodes to retain their links and labels.
            // A single flex row avoids two independently sized server navbars.
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
                style.textContent = `#container { min-width: 0; width: 100%; }
                    #content { min-width: 0; max-width: 100%; box-sizing: border-box; }
                    `;
                document.head.append(style);
            }
            """#, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let page = PageSession(WebPage(configuration: configuration), owner: self)
        pages[key] = page
        return page
    }
}

private struct ServerWebView: View {
    let url: URL
    let title: String
    let session: PageSession
    private var page: WebPage { session.page }
    var reloadID: UUID? = nil
    var body: some View {
        WebView(page)
            .overlay {
                if let errorMessage = session.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn’t open \(title)", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") { session.load(url, requestID: reloadID, force: true) }.buttonStyle(.glass)
                    }.background(.background)
                }
            }
            #if os(iOS)
            .navigationTitle(title)
            #endif
            .task(id: reloadID) { session.load(url, requestID: reloadID) }
    }

}

private struct AddURLsView: View {
    @Bindable var model: SettingsModel
    let pages: WebPages
    var reloadID: UUID?
    @Environment(\.openURL) private var openURL
    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let server = model.verifiedServer {
                        ServerWebView(url: server.appending(path: "add/"), title: "Add URLs", session: pages.page(for: "add-\(server)"), reloadID: reloadID)
                            .id(server).frame(maxWidth: .infinity).frame(height: 580)
                    } else {
                        ContentUnavailableView("Connect your server", systemImage: "network", description: Text("Set up Connection Settings to use the embedded Add URLs form."))
                    }
                    VStack(alignment: .leading, spacing: 24) {
                    Text("More ways to add").font(.title2.bold())
                    Text("There are several ways you can add new URLs to archive.")
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("In any app, open Share → ArchiveBox (under More if needed) → Save to ArchiveBox, and keep the sheet open until it finishes.")
                            Image("ShareSheetGuide").resizable().scaledToFit().frame(maxHeight: 320)
                                .accessibilityLabel("iPhone share sheet with ArchiveBox available in the Apps list")
                            Picker(
                                "Default persona",
                                selection: Binding(
                                    get: { model.persona },
                                    set: {
                                        model.persona = $0
                                        model.save()
                                    })
                            ) {
                                Text("Server default").tag("")
                                ForEach(model.personas) { persona in Text(persona.name).tag(persona.name) }
                                if !model.persona.isEmpty && !model.personas.contains(where: { $0.name == model.persona }) {
                                    Text(model.personasLoaded ? "\(model.persona) (not found on server)" : model.persona).tag(model.persona)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("defaultPersona")
                            .disabled(model.verifiedToken == nil || model.busy)
                            Button("Refresh personas", systemImage: "arrow.clockwise") {
                                Task { await model.refreshPersonas() }
                            }
                            .disabled(model.verifiedToken == nil || model.busy)
                            if let message = model.personaError {
                                Text("Couldn’t refresh personas: \(message) Your saved persona has not changed.").foregroundStyle(.red)
                            }

                            Text("Default Persona applies to native share-sheet saves. Browser extensions and the web form have their own persona controls.").font(.footnote)
                                .foregroundStyle(.secondary)
                            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("Share Sheet", systemImage: "square.and.arrow.up")
                    }
                    GroupBox("Browser Extension") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(
                                "Import browser bookmarks or history, save URLs by clicking the extension icon, and include cookies for authenticated pages. Choose your browser to install or enable ArchiveBox."
                            )
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    #if os(macOS)
                                        Button("Safari", systemImage: "safari") {
                                            SFSafariApplication.showPreferencesForExtension(withIdentifier: "io.archivebox.ArchiveBox.Safari") { error in
                                                if let error { Task { @MainActor in model.errorMessage = error.localizedDescription } }
                                            }
                                        }
                                    #else
                                        if #available(iOS 26.2, *) {
                                            Button("Safari", systemImage: "safari") {
                                                SFSafariSettings.openExtensionsSettings(forIdentifiers: ["io.archivebox.ArchiveBox.Safari"]) { error in
                                                    if let error { model.errorMessage = error.localizedDescription }
                                                }
                                            }
                                        }
                                    #endif
                                    ForEach(
                                        [
                                            ("Chrome", "Chrome", "https://chromewebstore.google.com/detail/archivebox/habonpimjphpdnmcfkaockjnffodikoj"),
                                            ("Brave", "Brave", "https://chromewebstore.google.com/detail/archivebox/habonpimjphpdnmcfkaockjnffodikoj"),
                                            ("Firefox", "Firefox", "https://addons.mozilla.org/firefox/addon/archivebox-exporter/"),
                                            ("Source Code", "GitHubMark", "https://github.com/ArchiveBox/archivebox-browser-extension"),
                                        ], id: \.0
                                    ) { name, icon, address in
                                        Button {
                                            openURL(URL(string: address)!)
                                        } label: {
                                            Label {
                                                Text(name)
                                            } icon: {
                                                Image(icon).resizable().scaledToFit().frame(width: 16, height: 16)
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            #if !os(macOS)
                                if #unavailable(iOS 26.2) {
                                    Text("Safari: Settings → Apps → Safari → Extensions → ArchiveBox")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            #endif
                            Text(
                                "Safari automatically uses the connection saved here. For Chrome, Brave, and Firefox, enter your server URL and API key in the extension. Brave uses the Chrome Web Store."
                            )
                            .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    GroupBox("And more…") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(
                                [
                                    ("REST API", "https://github.com/ArchiveBox/ArchiveBox/issues/496#issuecomment-2080174235"),
                                    ("Command-line interface", "https://github.com/ArchiveBox/ArchiveBox/wiki/Usage#cli-usage"),
                                    ("SQLite / SQL shell", "https://github.com/ArchiveBox/ArchiveBox/wiki/Usage#sql-shell-usage"),
                                    ("Supported sources", "https://github.com/ArchiveBox/ArchiveBox/wiki/Quickstart#2-get-your-list-of-urls-to-archive"),
                                ], id: \.0
                            ) { title, address in
                                Link(title, destination: URL(string: address)!)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    }.padding(20).frame(maxWidth: 1000)
                }.frame(maxWidth: .infinity)
            }
    }
}
