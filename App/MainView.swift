import SwiftUI
import ArchiveBoxCore
import UserNotifications
import AppIntents
import CoreSpotlight

struct MainView: View {
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Bindable var settings: SettingsModel
    var settingsNavigationID: UUID? = nil
    var addNavigationID: UUID? = nil
    @State private var incomingServer: URL?
    @State private var incomingAPIKey: String?
    @State private var confirmingServer = false
    @State private var didChooseLaunchScreen = false
    @State private var selection: Screen? = .settings
    @State private var pages = WebPages()
    @State private var reloadIDs: [Screen: UUID] = [:]
    @State private var compactColumn: NavigationSplitViewColumn = .detail
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var archiveNavigation = ArchiveNavigation.shared
    @State private var searchQuery = ""
    @State private var openedPage: OpenedPage?
    @State private var routeError: String?

    // Keep the sheet and its authenticated session in one presentation value.
    // Separate @State captured only inside a sheet can retain its initial nil.
    private struct OpenedPage: Identifiable {
        let page: ArchiveBoxSearchResult
        let configuration: ServerConfiguration
        var id: String { page.id }
    }

    private enum Screen: String, CaseIterable {
        case add, search, agent, activity, crawls, schedules, snapshots, results, tags, admin, users, personas, keys, webhooks
        case processes, machines, interfaces, binaries, plugins, workers, logs, github, docs, bugs, forum, extensionSource, settings

        var info: (title: String, icon: String, path: String) {
            switch self {
            case .add: ("Add URLs", "plus", "add/")
            case .search: ("Search Archive", "magnifyingglass", "")
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
        Group {
            if !didChooseLaunchScreen {
                ProgressView("Opening ArchiveBox…")
            } else if settings.showsSetupGuide {
                SetupGuide(connect: {
                    settings.dismissSetupGuide()
                    activate(.settings)
                }, chooseServer: { url in
                    settings.useDiscoveredServer(url); activate(.settings)
                }, useMac: {
                    #if os(macOS)
                    settings.selectConnection(.local)
                    #endif
                    settings.dismissSetupGuide()
                    activate(.settings)
                })
            } else {
                mainNavigation(visibility: visibility)
            }
        }
        .task {
            guard !didChooseLaunchScreen else { return }
            settings.load()
            ArchiveBoxShortcuts.updateAppShortcutParameters()
            ArchiveSystemIndex.connectionChanged()
            didChooseLaunchScreen = true
            #if os(iOS)
            // A saved connection should open normally even when offline.
            if !settings.serverText.isEmpty && !settings.tokenText.isEmpty {
                selection = .snapshots
                compactColumn = .sidebar
                columnVisibility = .all
            }
            #endif
        }
        .task(id: settings.verifiedToken) {
            // Ask after setup gives this permission context, not over the welcome.
            guard settings.verifiedToken != nil else { return }
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        }
        .task(id: settings.verifiedServer) {
            guard settings.verifiedServer != nil else { return }
            while !Task.isCancelled {
                await settings.refreshReachability()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
        .onChange(of: settings.serverReachable) { _, reachable in
            if reachable { pages.reconnectFailedPages() }
        }
        .onChange(of: "\(settings.verifiedServer?.absoluteString ?? "")\n\(settings.verifiedToken ?? "")", initial: true) {
            pages.configure(server: settings.verifiedServer, baseURL: settings.displayedBaseURL, token: settings.verifiedToken)
        }
        .confirmationDialog("Connect to this ArchiveBox server?", isPresented: $confirmingServer) {
            Button("Use this server") {
                if let incomingServer { settings.useConnectionLink(incomingServer, apiKey: incomingAPIKey); activate(.settings) }
                incomingAPIKey = nil
            }
            Button("Cancel", role: .cancel) { incomingAPIKey = nil; incomingServer = nil }
        } message: { Text(incomingServer?.absoluteString ?? "") }
        .onOpenURL { url in
            if let route = ArchiveRoute(url: url) { archiveNavigation.open(route); return }
            if let server = ConnectionLink.server(from: url) {
                settings.load()
                incomingServer = server
                incomingAPIKey = ConnectionLink.apiKey(from: url)
                if settings.serverText.isEmpty {
                    settings.useConnectionLink(server, apiKey: incomingAPIKey); activate(.settings)
                    incomingAPIKey = nil
                } else { confirmingServer = true }
            }
            #if os(macOS)
            if url.scheme == "archivebox", url.host == "admin" { activate(.admin) }
            if url.scheme == "archivebox", url.host == "safari-extension-settings" {
                BrowserExtensionSetup.openSafariSettings { error in
                    if let error { settings.errorMessage = error.localizedDescription; activate(.add) }
                }
            }
            #endif
        }
        .onContinueUserActivity("io.archivebox.viewSnapshot") { activity in
            if let value = activity.userInfo?["route"] as? String,
               let url = URL(string: value), let route = ArchiveRoute(url: url) { archiveNavigation.open(route) }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let value = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
               let url = URL(string: EntityIdentifier(activityIdentifier: value)?.identifier ?? value),
               let route = ArchiveRoute(url: url) { archiveNavigation.open(route) }
        }
        .task(id: archiveNavigation.requestID) {
            guard let route = archiveNavigation.route else { return }
            switch route {
            case .search(let query): searchQuery = query; activate(.search)
            case .add: activate(.add)
            case .snapshot(let server, let id):
                do {
                    let configuration = try AppEnvironment.requireConfiguration()
                    guard server == configuration.server else {
                        throw ArchiveBoxError.message("This page belongs to a different ArchiveBox server. Connect to that server in Settings before opening the link.")
                    }
                    let snapshot = try await ArchiveBoxClient().snapshot(id: id, configuration: configuration)
                    try Task.checkCancellation()
                    guard try AppEnvironment.store.load() == configuration else { return }
                    let page = ArchiveBoxSearchResult(snapshot: snapshot, server: server)
                    openedPage = OpenedPage(page: page, configuration: configuration)
                    if #available(iOS 27.0, macOS 27.0, *) {
                        let intent = OpenArchivedPageWithSiriIntent()
                        intent.target = page
                        do { try await intent.donate() }
                        catch { NSLog("ArchiveBox action donation failed: %@", error.localizedDescription) }
                    }
                    do { try await ArchiveSystemIndex.update([page], configuration: configuration) }
                    catch { NSLog("ArchiveBox Spotlight indexing failed: %@", error.localizedDescription) }
                } catch { if !Task.isCancelled { routeError = error.localizedDescription } }
            }
        }
        .sheet(item: $openedPage) { opened in
            let page = opened.page
            let configuration = opened.configuration
            NavigationStack {
                ArchivedPageView(page: page, session: pages.page(for: page.id, baseURL: settings.displayedBaseURL,
                    server: configuration.server, token: configuration.token))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { openedPage = nil } } }
            }
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 600)
            #endif
        }
        .alert("Couldn’t open archived page", isPresented: Binding(get: { routeError != nil }, set: { if !$0 { routeError = nil } })) {
            Button("OK") { routeError = nil }
        } message: { Text(routeError ?? "") }
        .onChange(of: addNavigationID) { activate(.add) }
        .onChange(of: settingsNavigationID) {
            settings.dismissSetupGuide()
            activate(.settings)
        }
        .onChange(of: settings.adminNavigationID) {
            selection = .admin
            compactColumn = .detail
        }
        .onChange(of: settings.verifiedServer) { old, new in
            if old != nil && old != new { openedPage = nil }
            if settings.verifiedServer == nil, let selection, !selection.isHelp, selection != .add { self.selection = .settings }
        }
    }

    private func mainNavigation(visibility: Binding<NavigationSplitViewVisibility>) -> some View {
        NavigationSplitView(columnVisibility: visibility, preferredCompactColumn: $compactColumn) {
            List {
                rows([.add, .agent])
                Section("Collection") { rows([.search, .snapshots, .crawls, .schedules, .results, .tags]) }
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
                else if screen == .search {
                    ArchiveSearchView(settings: settings, initialQuery: searchQuery) { page in
                        if let route = ArchiveRoute(url: page.appURL) { archiveNavigation.open(route) }
                    }
                }
                else {
                    Group {
                        if screen == .add { AddURLsView(model: settings, pages: pages, reloadID: reloadIDs[.add]) }
                        else if let url = destination(screen) {
                            ServerWebView(url: url, title: screen.info.title, session: pages.page(for: "\(screen.rawValue)-\(url)", baseURL: settings.displayedBaseURL,
                                server: settings.verifiedServer, token: settings.verifiedToken),
                                          reloadID: screen == .admin ? settings.adminNavigationID : reloadIDs[screen])
                                .id("\(screen.rawValue)-\(url)")
                        } else {
                            ContentUnavailableView("Connect your server", systemImage: "network", description: Text("Choose Connection Settings to get started."))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if os(iOS)
                    // Web content fills the home-indicator area as well as the detail column.
                    .ignoresSafeArea(.container, edges: .bottom)
                    #endif
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
            .toolbar(screen == .settings || screen == .search ? .visible : .hidden, for: .navigationBar)
            .background {
                if screen != .settings && screen != .search {
                    Color(red: 165.0 / 255, green: 28.0 / 255, blue: 80.0 / 255)
                        .ignoresSafeArea(.container, edges: .top)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if screen == .activity {
                    // Activity strips the server header, so reserve a native bar
                    // for the menu button instead of covering the live status text.
                    Text(screen.info.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 64)
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .background(Color(red: 165.0 / 255, green: 28.0 / 255, blue: 80.0 / 255))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("navigation.activity.title")
                }
            }
            .overlay(alignment: .topLeading) {
                if screen != .settings && screen != .search && (horizontalSizeClass == .compact || columnVisibility == .detailOnly) {
                    Button {
                        withAnimation {
                            compactColumn = .sidebar
                            columnVisibility = .all
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 1)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to menu")
                    .accessibilityIdentifier("navigation.sidebar")
                    .padding(8)
                }
            }
            #endif
        }
        #if os(macOS)
        // Hiding the window toolbar also removes traffic lights. Keep its controls,
        // but let web content fill the transparent titlebar in the detail column.
        .toolbarBackgroundVisibility(selection == nil || selection == .settings ? .automatic : .hidden, for: .windowToolbar)
        #endif
    }

    @ViewBuilder private func rows(_ screens: [Screen]) -> some View {
        ForEach(screens, id: \.self) { screen in
            Button { activate(screen) } label: {
                Label(screen.info.title, systemImage: screen.info.icon)
                    .fontWeight(screen == .snapshots ? .semibold : .regular)
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
