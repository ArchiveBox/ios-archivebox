import SwiftUI
import ArchiveBoxCore
import UserNotifications
import AppIntents
import CoreSpotlight
#if os(iOS)
import UIKit
#endif

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
    @State private var focusSearch = false
    @State private var snapshotDestination: URL?
    @State private var routeError: String?

    private enum Screen: String, CaseIterable {
        case add, search, agent, activity, crawls, schedules, snapshots, results, tags, domains, importers, admin, users, personas, keys, webhooks
        case processes, machines, interfaces, binaries, plugins, workers, logs, github, docs, bugs, forum, extensionSource, settings

        var info: (title: String, icon: String, path: String) {
            switch self {
            case .add: ("Add URLs", "plus", "add/")
            case .search: ("Search Archive", "magnifyingglass", "admin/core/snapshot/")
            case .agent: ("AI Agent", "sparkles", "admin/agent/")
            case .activity: ("Activity", "arrow.down.circle", "admin/")
            case .crawls: ("Crawl Jobs", "point.3.connected.trianglepath.dotted", "admin/crawls/crawl/")
            case .schedules: ("Scheduled Crawls", "calendar.badge.clock", "admin/crawls/crawlschedule/")
            case .snapshots: ("Snapshots", "building.columns", "admin/core/snapshot/grid/")
            case .results: ("Archive Results", "doc.richtext", "admin/core/archiveresult/")
            case .tags: ("Tags", "tag", "admin/core/tag/")
            case .domains: ("Domains", "globe", "admin/domains/")
            case .importers: ("Importers", "tray.and.arrow.down", "admin/importers/")
            case .admin: ("Admin", "person.crop.circle", "admin/")
            case .users: ("Users", "person.2", "admin/auth/user/")
            case .personas: ("Personas", "person.crop.rectangle.stack", "admin/personas/persona/")
            case .keys: ("API Keys", "key", "admin/api/apitoken/")
            case .webhooks: ("Rules Engine", "arrow.triangle.branch", "admin/rules/")
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
            pages.onWebLogin = { [weak settings, weak authentication = pages.authentication] page in
                guard let settings, let authentication else { return }
                settings.useWebLogin(page, authentication: authentication)
            }
            pages.configure(server: settings.verifiedServer, baseURL: settings.displayedBaseURL, token: settings.verifiedToken)
        }
        .task(id: "\(settings.verifiedServer?.absoluteString ?? "")\n\(settings.verifiedToken ?? "")") {
            guard let server = settings.verifiedServer, let token = settings.verifiedToken else { return }
            // A first embedded page otherwise pays for browser-session creation
            // after its tap. Begin it when the verified connection is available.
            pages.configure(server: server, baseURL: settings.displayedBaseURL, token: token)
            try? await pages.authenticate()
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
            case .search(let query):
                searchQuery = query
                focusSearch = query.isEmpty
                activate(.search)
            case .add: activate(.add)
            case .snapshot(let server, let id):
                do {
                    let configuration = try AppEnvironment.requireConfiguration()
                    guard server == configuration.server else {
                        throw ArchiveBoxError.message("This page belongs to a different ArchiveBox server. Connect to that server in Settings before opening the link.")
                    }
                    let snapshot = try await ArchiveBoxClient().snapshot(id: id, configuration: configuration)
                    try Task.checkCancellation()
                    guard try AppEnvironment.store.load().active_server == configuration else { return }
                    let page = ArchiveBoxSearchResult(snapshot: snapshot, server: server)
                    openSnapshot(page.archiveURL)
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
            #if os(iOS)
            columnVisibility = .detailOnly
            #endif
        }
        .onChange(of: settings.verifiedServer) { old, new in
            if old != nil && old != new {
                snapshotDestination = nil; searchQuery = ""
                focusSearch = false
            }
        }
    }

    private var usesPhoneHome: Bool {
        #if os(iOS)
        // A narrow iPad window still uses the sidebar layout. The full-screen
        // iPhone menu alone puts its actions within thumb reach.
        UIDevice.current.userInterfaceIdiom == .phone && horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    private func mainNavigation(visibility: Binding<NavigationSplitViewVisibility>) -> some View {
        NavigationSplitView(columnVisibility: visibility, preferredCompactColumn: $compactColumn) {
            sidebarColumn
        } detail: {
            let screen = selection ?? .settings
            Group {
                if screen == .settings { SettingsView(model: settings) }
                else if !screen.isHelp && !(screen == .admin && settings.recoveringSavedKey) && (settings.switchingServer || (settings.busy && !settings.tokenText.isEmpty && settings.verifiedToken == nil)) {
                    ProgressView("Connecting to server…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("server.switching")
                }
                else if !screen.isHelp && !(screen == .admin && settings.recoveringSavedKey) && !settings.tokenText.isEmpty && settings.verifiedToken == nil {
                    ContentUnavailableView {
                        Label("Couldn’t connect", systemImage: "network")
                    } description: {
                        Text(settings.tokenError ?? settings.serverError ?? "Checking your saved connection…")
                    } actions: {
                        if let saved = settings.rememberedServers.first(where: { $0.id == settings.server_id }) {
                            Button("Reconnect") { settings.useRememberedServer(saved) }
                                .disabled(settings.busy)
                        }
                    }
                }
                else {
                    Group {
                        if screen == .add { AddURLsView(model: settings, pages: pages, reloadID: reloadIDs[.add]) }
                        else if let url = destination(screen) {
                            let session = pages.page(for: "\(screen.rawValue)-\(url)", baseURL: settings.displayedBaseURL,
                                server: settings.verifiedServer, token: settings.verifiedToken)
                            ServerWebView(url: url, title: screen.info.title, session: session,
                                          reloadID: screen == .admin ? settings.adminNavigationID : reloadIDs[screen])
                                .onChange(of: ObjectIdentifier(session), initial: true) {
                                    session.routing.openSnapshot = screen == .search ? { openSnapshot($0) } : nil
                                }
                                .task(id: screen == .search && focusSearch && !session.isLoading && !session.navigationLoading) {
                                    guard screen == .search, focusSearch, !session.isLoading,
                                          !session.navigationLoading, session.errorMessage == nil else { return }
                                    // The authenticated server page owns autocomplete, editing and live
                                    // results. Older servers expose the plain Django input on this same form.
                                    let didFocus = try? await session.page.evaluateJavaScript("""
                                        (() => {
                                            const form = document.querySelector('#changelist-search');
                                            const editor = form?.querySelector('[role="combobox"]') ?? form?.querySelector('#searchbar');
                                            if (!editor) return false;
                                            editor.focus();
                                            return document.activeElement === editor;
                                        })()
                                        """) as? Bool
                                    guard !Task.isCancelled else { return }
                                    if didFocus == true { focusSearch = false }
                                }
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
            .toolbar(screen == .settings ? .visible : .hidden, for: .navigationBar)
            .background {
                if screen != .settings {
                    detailHeaderColor
                        .ignoresSafeArea(.container, edges: .top)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if screen == .activity {
                    // Activity renders without the server header.
                    ZStack(alignment: .leading) {
                        Text(screen.info.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 64)
                            .frame(maxWidth: .infinity)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("navigation.activity.title")
                        if showsDetailBack {
                            detailBackButton.padding(.leading, 8)
                        }
                    }
                    .frame(height: 60)
                    .background(detailHeaderColor)
                } else if screen != .settings && usesNativePhoneDetailHeader {
                    HStack(spacing: 8) {
                        if showsDetailBack { detailBackButton }
                        phoneHomeBrand
                            .foregroundStyle(.white)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("navigation.brand")
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(detailHeaderColor)
                }
            }
            .overlay(alignment: .topLeading) {
                // Preserve the existing tablet layout. On iPhone and Activity
                // the button owns a row; WebKit cannot scroll content under it.
                if screen != .settings && screen != .activity && !usesNativePhoneDetailHeader && showsDetailBack {
                    detailBackButton
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                        .offset(y: -5)
                }
            }
            #endif
        }
        #if os(iOS)
        // Record the split view's actual response to a tap when UI automation cannot reach the sidebar.
        .onChange(of: compactColumn) { _, value in
            NSLog("ArchiveBox sidebar compact changed: %@", String(describing: value))
        }
        .onChange(of: columnVisibility) { _, value in
            NSLog("ArchiveBox sidebar visibility changed: %@", String(describing: value))
        }
        #endif
        #if os(macOS)
        // Hiding the window toolbar also removes traffic lights. Keep its controls,
        // but let web content fill the transparent titlebar in the detail column.
        .toolbarBackgroundVisibility(selection == nil || selection == .settings ? .automatic : .hidden, for: .windowToolbar)
        #endif
    }

    private var isTabletSidebar: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    private var sidebarRailInsets: EdgeInsets? {
        isTabletSidebar ? EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6) : nil
    }

    private var sidebarColumn: some View {
        Group {
            #if os(iOS)
            if usesPhoneHome {
                sidebarList
                    .contentMargins(.top, 0, for: .scrollContent)
                    .listSectionSpacing(.compact)
                    .safeAreaInset(edge: .top, spacing: 0) { phoneHomeHeader }
                    .safeAreaInset(edge: .bottom, spacing: 0) { phoneHomeActions }
            } else {
                // The rail owns its footer; the scrolling viewport ends above it.
                VStack(spacing: 0) {
                    sidebarList
                        .contentMargins(.horizontal, isTabletSidebar ? 4 : nil, for: .scrollContent)
                    Divider()
                    sidebarSummary().background(Color(uiColor: .systemBackground).ignoresSafeArea(edges: .bottom))
                }
            }
            #else
            sidebarList.safeAreaInset(edge: .bottom, spacing: 0) { sidebarSummary() }
            #endif
        }
        #if os(iOS)
        .navigationTitle(isTabletSidebar ? "" : "ArchiveBox")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(usesPhoneHome || alignsTabletWebHeader ? .hidden : .automatic, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            if alignsTabletWebHeader {
                // One-line embedded admin headers use a 44px border box.
                tabletSidebarTitle
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(detailHeaderColor.ignoresSafeArea(edges: .top))
            }
        }
        .toolbar {
            if isTabletSidebar && !alignsTabletWebHeader {
                ToolbarItem(placement: .principal) {
                    tabletSidebarTitle
                        .fixedSize(horizontal: true, vertical: false)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        #endif
        #if os(macOS)
        .navigationTitle("ArchiveBox")
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
    }

    private var sidebarList: some View {
        List {
            if usesPhoneHome {
                sidebarSummary(compactHome: true)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                Section("Collection") { rows([.crawls, .snapshots, .tags, .schedules, .results, .domains, .importers, .agent]) }
            } else {
                serverSwitcher.listRowInsets(sidebarRailInsets)
                sidebarSearch.listRowInsets(sidebarRailInsets)
                rows([.add, .agent])
                Section("Collection") { rows([.snapshots, .crawls, .schedules, .results, .tags, .domains, .importers]) }
            }
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
        .accessibilityIdentifier("sidebar")
    }

    private func sidebarSummary(compactHome: Bool = false) -> some View {
        SidebarSummary(settings: settings, authentication: pages.authentication,
                       sidebarVisible: columnVisibility != .detailOnly, compactHome: compactHome) { activate(.activity) }
    }

    @ViewBuilder private var serverSwitcher: some View {
        if settings.quickSwitchServers.count > 1 {
            Menu {
                ForEach(settings.quickSwitchServers) { server in
                    Button {
                        guard server.id != settings.server_id else { return }
                        settings.useRememberedServer(server)
                    } label: {
                        Label(server.server.absoluteString,
                              systemImage: server.id == settings.server_id ? "checkmark.circle.fill" : "server.rack")
                    }
                    .accessibilityIdentifier("sidebar.switchServer.\(server.id)")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                    #if os(iOS)
                    let name = settings.quickSwitchServers.first { $0.id == settings.server_id }?.name
                    Text(name.flatMap { $0.isEmpty ? nil : $0 } ?? settings.displayedBaseURL?.host() ?? "Choose server")
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").imageScale(.small)
                    #else
                    Text(settings.displayedBaseURL?.host() ?? "Choose server")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    #endif
                }
            }
            .accessibilityIdentifier("sidebar.serverSwitcher")
        }
    }

    private var sidebarSearch: some View {
        Button {
            focusSearch = true
            activate(.search, reloadIfSelected: false)
        } label: {
            Label("Search archive", systemImage: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                #if os(iOS)
                .frame(minHeight: 44)
                .background(.quaternary, in: Capsule())
                #else
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                #endif
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.search")
        .disabled(settings.verifiedServer == nil)
    }

    #if os(iOS)
    private var alignsTabletWebHeader: Bool {
        // Only a persistent iPad rail sits beside the embedded admin header.
        // Settings, Activity and the dedicated replay header retain their own chrome.
        isTabletSidebar && horizontalSizeClass == .regular && columnVisibility != .detailOnly
            && selection != nil && selection != .settings && selection != .activity
            && !(selection == .snapshots && snapshotDestination != nil)
    }

    private var tabletSidebarTitle: some View {
        Text("ArchiveBox")
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("sidebar.title")
    }

    private var detailHeaderColor: Color {
        Color(red: 165.0 / 255, green: 28.0 / 255, blue: 80.0 / 255)
    }

    private var usesNativePhoneDetailHeader: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private var showsDetailBack: Bool {
        horizontalSizeClass == .compact || columnVisibility == .detailOnly
    }

    private var detailBackButton: some View {
        SidebarBackButton {
            settings.preserveExplicitNavigation()
            NSLog("ArchiveBox sidebar navigation tap: screen=%@ compact=%@ visibility=%@",
                  selection?.rawValue ?? "", String(describing: compactColumn), String(describing: columnVisibility))
            withAnimation {
                compactColumn = .sidebar
                columnVisibility = .all
            }
            NSLog("ArchiveBox sidebar navigation requested: compact=%@ visibility=%@",
                  String(describing: compactColumn), String(describing: columnVisibility))
        }
        .frame(width: 44, height: 44)
    }

    private var phoneHomeBrand: some View {
        HStack(spacing: 8) {
            Image("BrandLogo")
                .resizable().scaledToFit().frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            Text("ArchiveBox")
                .font(.headline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .layoutPriority(1)
        }
    }

    private var phoneHomeHeader: some View {
        HStack(spacing: 8) {
            phoneHomeBrand
            if settings.quickSwitchServers.count > 1 {
                Spacer(minLength: 8)
                serverSwitcher.font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: settings.quickSwitchServers.count > 1 ? .leading : .center)
        .foregroundStyle(.white)
        .tint(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.ignoresSafeArea(edges: .top))
    }

    private var phoneHomeActions: some View {
        HStack(spacing: 10) {
            sidebarSearch
            Button { activate(.add) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                    Text("Add")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 44)
                .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add URLs")
            .accessibilityIdentifier("sidebar.add")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(.regularMaterial)
    }
    #endif

    @ViewBuilder private func rows(_ screens: [Screen]) -> some View {
        ForEach(screens, id: \.self) { screen in
            let title = screen.info.title
            Button { activate(screen) } label: {
                Label(title, systemImage: screen.info.icon)
                    .fontWeight(screen == .snapshots ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .listRowInsets(sidebarRailInsets)
                .listRowBackground(selection == screen ? Color.accentColor.opacity(0.18) : Color.clear)
                .accessibilityAddTraits(selection == screen ? .isSelected : [])
                .accessibilityIdentifier("sidebar.\(screen.rawValue)")
                .accessibilityHint(screen.isHelp ? "Opens in your browser" : "Shows \(title)")
                .disabled(screen != .add && screen != .settings && !screen.isHelp && settings.verifiedServer == nil)
        }
    }

    private func activate(_ screen: Screen, reloadIfSelected: Bool = true) {
        settings.preserveExplicitNavigation()
        if screen.isHelp, let url = URL(string: screen.info.path) { openURL(url); return }
        // Only an explicit repeat click resets the page. Switching away and back
        // retains the cached page, including its current URL and form contents.
        if selection == screen && reloadIfSelected {
            if screen == .admin { settings.openAdmin(settings.adminURL) }
            else {
                if screen == .snapshots { snapshotDestination = nil }
                reloadIDs[screen] = UUID()
            }
        }
        selection = screen
        compactColumn = .detail
        #if os(iOS)
        // A compact split view needs a visibility change when returning to
        // the menu; keep it in step with the preferred column.
        columnVisibility = .detailOnly
        #endif
    }

    private func openSnapshot(_ url: URL) {
        settings.preserveExplicitNavigation()
        snapshotDestination = url
        reloadIDs[.snapshots] = UUID()
        selection = .snapshots
        compactColumn = .detail
        #if os(iOS)
        columnVisibility = .detailOnly
        #endif
    }

    private func destination(_ screen: Screen) -> URL? {
        if screen == .snapshots, let snapshotDestination { return snapshotDestination }
        if screen == .search, let server = settings.verifiedServer {
            let items = searchQuery.isEmpty ? [] : [URLQueryItem(name: "q", value: searchQuery)]
            return server.appending(path: screen.info.path).appending(queryItems: items)
        }
        if screen.isHelp { return nil }
        if screen == .admin, let target = settings.adminDestination { return target }
        return settings.verifiedServer?.appending(path: screen.info.path)
    }
}

#if os(iOS)
// A plain SwiftUI overlay hit-tests to the WKWebView below it. Its scroll
// gestures can consume Back taps even when accessibility says the button is
// hittable. A native control owns this 44-point target independently of WebKit.
private struct SidebarBackButton: UIViewRepresentable {
    var action: () -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "chevron.left", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        button.tintColor = .white
        button.accessibilityLabel = "Back to menu"
        button.accessibilityIdentifier = "navigation.sidebar"
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.6
        button.layer.shadowRadius = 1
        button.layer.shadowOffset = .zero
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        let identifier = UIAction.Identifier("showSidebar")
        button.removeAction(identifiedBy: identifier, for: .touchUpInside)
        button.addAction(UIAction(identifier: identifier) { _ in action() }, for: .touchUpInside)
    }
}
#endif
