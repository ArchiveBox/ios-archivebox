import SwiftUI
import ArchiveBoxCore

struct MainView: View {
    @Environment(\.openURL) private var openURL
    @Bindable var settings: SettingsModel
    var settingsNavigationID: UUID? = nil
    var addNavigationID: UUID? = nil
    @State private var didChooseLaunchScreen = false
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
        #if os(macOS)
        // The Mac sidebar is permanent navigation; only iPhone/iPad collapse it.
        let visibility = Binding.constant(NavigationSplitViewVisibility.all)
        #else
        let visibility = $columnVisibility
        #endif
        NavigationSplitView(columnVisibility: visibility, preferredCompactColumn: $compactColumn) {
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
                SidebarSummary(settings: settings, authentication: pages.authentication, sidebarVisible: columnVisibility != .detailOnly) { activate(.activity) }
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
            .toolbar(removing: .sidebarToggle)
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
                            ServerWebView(url: url, title: screen.info.title, session: pages.page(for: "\(screen.rawValue)-\(url)", baseURL: settings.displayedBaseURL),
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
        .task {
            guard !didChooseLaunchScreen else { return }
            didChooseLaunchScreen = true
            settings.load()
            #if os(iOS)
            // A stored connection was already verified when saved. Open the menu
            // immediately while rechecking it, including when the device is offline.
            if !settings.serverText.isEmpty && !settings.tokenText.isEmpty {
                selection = .snapshots
                compactColumn = .sidebar
                columnVisibility = .all
            }
            #endif
        }
        .task(id: "\(settings.verifiedServer?.absoluteString ?? "")\n\(settings.verifiedToken ?? "")") {
            await pages.configure(server: settings.verifiedServer, baseURL: settings.displayedBaseURL, token: settings.verifiedToken)
        }
        #if os(macOS)
        .onOpenURL { url in
            // Navigation only: external links must never replace the saved server or credentials.
            if url.scheme == "archivebox", url.host == "admin" { activate(.admin) }
            if url.scheme == "archivebox", url.host == "safari-extension-settings" {
                BrowserExtensionSetup.openSafariSettings { error in
                    if let error { settings.errorMessage = error.localizedDescription; activate(.add) }
                }
            }
        }
        #endif
        .onChange(of: addNavigationID) { activate(.add) }
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
                .accessibilityHint(screen.isHelp ? "Opens in your browser" : "Shows \(screen.info.title)")
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
