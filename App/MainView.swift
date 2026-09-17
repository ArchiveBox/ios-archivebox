import SafariServices
import SwiftUI
import WebKit

struct MainView: View {
    @Bindable var settings: SettingsModel
    @State private var selection: Screen? = .settings
    @State private var pages = WebPages()
    @State private var compactColumn: NavigationSplitViewColumn = .detail

    private enum Screen: String, CaseIterable {
        case add, agent, crawls, schedules, snapshots, results, tags, admin, users, personas, keys, webhooks
        case processes, machines, interfaces, binaries, github, docs, bugs, forum, extensionSource, settings

        var info: (title: String, icon: String, path: String) {
            switch self {
            case .add: ("Add URLs", "plus", "add/")
            case .agent: ("AI Agent", "sparkles", "admin/agent/")
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
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            List(selection: $selection) {
                rows([.add, .agent])
                Section("Collection") { rows([.crawls, .schedules, .snapshots, .results, .tags]) }
                Section {
                    rows([.users, .personas, .keys, .webhooks, .processes, .machines, .interfaces, .binaries])
                } header: {
                    NavigationLink(value: Screen.admin) {
                        HStack { Text("Admin"); Image(systemName: "arrow.up.right").imageScale(.small) }
                    }
                    .buttonStyle(.plain).disabled(settings.verifiedServer == nil)
                    .simultaneousGesture(TapGesture().onEnded { settings.openAdmin(settings.adminURL) })
                    .accessibilityLabel("Admin home").accessibilityIdentifier("sidebar.admin")
                }
                Section("Help") { rows([.github, .docs, .bugs, .forum, .extensionSource]) }
                Section { rows([.settings]) }
            }
            .listStyle(.sidebar)
            .navigationTitle("ArchiveBox")
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Image("BrandLogo")
                        .resizable().scaledToFit().frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("ArchiveBox")
                }
            }
            #endif
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            let screen = selection ?? .settings
            if screen == .settings { SettingsView(model: settings) }
            else if screen == .add { AddURLsView(model: settings, pages: pages) }
            else {
                NavigationStack {
                    if let url = destination(screen) {
                        ServerWebView(url: url, title: screen.info.title, page: pages.page(for: "\(screen.rawValue)-\(url)"),
                                      reloadID: screen == .admin ? settings.adminNavigationID : nil)
                            .id("\(screen.rawValue)-\(url)")
                    } else {
                        ContentUnavailableView("Connect your server", systemImage: "network", description: Text("Choose Connection Settings to get started."))
                    }
                }
            }
        }
        .task { settings.load() }
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
            NavigationLink(value: screen) { Label(screen.info.title, systemImage: screen.info.icon) }
                .accessibilityIdentifier("sidebar.\(screen.rawValue)")
                .disabled(screen != .add && screen != .settings && !screen.isHelp && settings.verifiedServer == nil)
        }
    }

    private func destination(_ screen: Screen) -> URL? {
        if screen.isHelp { return URL(string: screen.info.path) }
        if screen == .admin, let target = settings.adminDestination { return target }
        return settings.verifiedServer?.appending(path: screen.info.path)
    }
}

// WebPage uses WebKit's persistent cookie store, shared by all embedded screens.
// The native API key never enters web content; normal server login handles sessions.
@MainActor private final class WebPages {
    private var pages: [String: WebPage] = [:]

    // Retain each screen's page independently, but allocate it only when visited.
    // All pages share the same persistent login cookie store.
    func page(for key: String) -> WebPage {
        if let page = pages[key] { return page }
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .default()
        // The server's Add template includes Django base.css (980px minimum)
        // without responsive.css. Load its own responsive rules inside this embed
        // and release the desktop width constraint; do not hide overflowing fields.
        configuration.userContentController.addUserScript(WKUserScript(source: #"""
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
                #header { min-width: 0; flex-shrink: 0; height: auto; }
                #header a { white-space: normal; overflow-wrap: anywhere; }`;
            document.head.append(style);
        }
        """#, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let page = WebPage(configuration: configuration)
        pages[key] = page
        return page
    }
}

private struct ServerWebView: View {
    let url: URL
    let title: String
    let page: WebPage
    var reloadID: UUID? = nil
    @State private var errorMessage: String?
    var body: some View {
        WebView(page)
            .overlay {
                if let errorMessage {
                    ContentUnavailableView {
                        Label("Couldn’t open \(title)", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") { Task { await load() } }.buttonStyle(.glass)
                    }.background(.background)
                }
            }
            .navigationTitle(title)
            // Returning from a successful login in another pane should not leave a
            // previously visited pane stranded on its cached login form.
            .task(id: reloadID) { if reloadID != nil || page.url == nil || page.url?.path.contains("/login/") == true { await load() } }
    }
    private func load() async {
        errorMessage = nil
        do { for try await _ in page.load(url) {} } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
}

private struct AddURLsView: View {
    @Bindable var model: SettingsModel
    let pages: WebPages
    @Environment(\.openURL) private var openURL
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let server = model.verifiedServer {
                        ServerWebView(url: server.appending(path: "add/"), title: "Add URLs", page: pages.page(for: "add-\(server)"))
                            .id(server).frame(maxWidth: .infinity).frame(height: 580)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        ContentUnavailableView("Connect your server", systemImage: "network", description: Text("Set up Connection Settings to use the embedded Add URLs form."))
                    }
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
            }.navigationTitle("Add URLs")
        }
    }
}
