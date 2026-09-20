import ArchiveBoxCore
import SwiftUI

@MainActor @Observable
final class SettingsModel {
    var showsSetupGuide = !UserDefaults.standard.bool(forKey: "setupGuideDismissed")

    func dismissSetupGuide() {
        UserDefaults.standard.set(true, forKey: "setupGuideDismissed")
        showsSetupGuide = false
    }

    func resetSetup() {
        do {
            try AppEnvironment.store.clear()
            ArchiveSystemIndex.connectionChanged()
            #if os(macOS)
            localServer.cancel()
            connectionMode = .remote
            UserDefaults.standard.removeObject(forKey: "connectionMode")
            #endif
            serverChanged()
            serverText = ""
            UserDefaults.standard.removeObject(forKey: "setupGuideDismissed")
            showsSetupGuide = true
        } catch { errorMessage = error.localizedDescription }
    }

    func useDiscoveredServer(_ url: URL) {
        #if os(macOS)
        selectConnection(.remote)
        #endif
        serverChanged()
        serverText = url.absoluteString
        dismissSetupGuide()
        scheduleValidation()
    }

    func useConnectionLink(_ url: URL, apiKey: String?) {
        guard let apiKey, !apiKey.isEmpty else { useDiscoveredServer(url); return }
        #if os(macOS)
        selectConnection([ServerAddress.localAPI, ServerAddress.localServer].contains(url) ? .local : .remote)
        #endif
        serverChanged()
        serverText = url.absoluteString
        dismissSetupGuide()
        validation = Task {
            await testServer()
            guard !Task.isCancelled, verifiedServer != nil else { return }
            tokenText = apiKey
            await testToken() // Validates and persists to Keychain before loading personas.
            if !Task.isCancelled, verifiedToken != nil { save() }
        }
    }

    var adminDestination: URL?
    var adminNavigationID = UUID()
    func openAdmin(_ url: URL?) {
        guard let url else { return }
        adminDestination = url; adminNavigationID = UUID()
    }

    var server_id: String?
    var serverText = ""
    var tokenText = ""
    var verifiedServer: URL?
    var verifiedToken: String?
    var serverMessage: String?
    var tokenMessage: String?
    var errorMessage: String?
    var savedMessage: String?
    var personas: [ServerPersona] = []
    var persona = ""
    var personaError: String?
    var personasLoaded = false
    var busy = false
    // Keep the last successful sample beyond the sidebar view's lifetime. Sleep,
    // background cancellation and temporary network failures do not erase it.
    var sidebarStatus: (progress: SidebarProgress, latency: Int)?
    private let client = ArchiveBoxClient()
    private var didLoad = false
    private var validation: Task<Void, Never>?
    var serverError: String?
    var serverReachable = false
    var tokenError: String?

    var adminURL: URL? { verifiedServer?.appending(path: "admin/") }
    var apiKeysURL: URL? { adminURL?.appending(path: "api/apitoken/") }
    var displayedBaseURL: URL? {
        guard let normalized = try? ServerAddress.normalize(serverText),
              var parts = URLComponents(url: normalized, resolvingAgainstBaseURL: false) else { return nil }
        if let host = parts.host, let prefix = ["api.", "admin.", "web."].first(where: { host.hasPrefix($0) }) {
            parts.host = String(host.dropFirst(prefix.count))
        }
        return parts.url
    }

    func scheduleValidation() {
        validation?.cancel()
        busy = false
        validation = Task {
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            if verifiedServer == nil && !serverText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await testServer() }
            guard !Task.isCancelled else { return }
            if verifiedServer != nil && !tokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await testToken() }
        }
    }
    #if os(macOS)
    enum ConnectionMode: String { case remote, local }
    var connectionMode = ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "connectionMode") ?? "remote") ?? .remote
    let localServer = LocalServer()

    private func savedConfiguration(for mode: ConnectionMode) throws -> ServerConfiguration? {
        let registry = try AppEnvironment.store.load()
        return registry.servers.first { configuration in
            let local = [ServerAddress.localAPI, ServerAddress.localServer].contains(configuration.server)
            return mode == .local ? local : !local
        }
    }

    func selectConnection(_ mode: ConnectionMode) {
        guard mode != connectionMode else { return }
        do {
            let config = try savedConfiguration(for: mode)
            serverChanged()
            connectionMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "connectionMode")
            serverText = config?.server.absoluteString ?? (mode == .local ? LocalServer.address : "")
            tokenText = config?.token ?? ""; persona = config?.persona ?? ""
            server_id = config?.id
            var registry = try AppEnvironment.store.load()
            registry.active_server_id = config?.id
            try AppEnvironment.store.save(registry)
            ArchiveSystemIndex.connectionChanged()
        } catch { errorMessage = error.localizedDescription }
        scheduleValidation()
    }

    func localServerReady(_ server: URL) async throws {
        serverText = server.absoluteString; verifiedServer = server
        serverReachable = true
        UserDefaults.standard.set(true, forKey: "setupGuideDismissed")
        serverError = nil
        serverMessage = "Connected to ArchiveBox Server on this Mac."
        if !tokenText.isEmpty {
            await testToken()
            if canSave { save() }
        }
    }
    #endif

    var canSave: Bool {
        verifiedServer != nil && verifiedToken == tokenText && !tokenText.isEmpty && !busy && (persona.isEmpty || (personasLoaded && personas.contains { $0.name == persona }))
    }

    func load() {
        // Revisiting Settings must preserve the current draft and connection checks.
        guard !didLoad else { return }
        didLoad = true
        do {
            #if os(macOS)
            // Each connection mode owns its credentials; a local profile must
            // never inherit a remote server's URL or API key.
            let config = try savedConfiguration(for: connectionMode)
            #else
            let config = try AppEnvironment.store.load().active_server
            #endif
            if let config {
                dismissSetupGuide()
                server_id = config.id
                serverText = config.server.absoluteString
                tokenText = config.token
                persona = config.persona ?? ""
                savedMessage = "Your saved connection is ready for the share sheet."
            }
            #if os(macOS)
            if config == nil && connectionMode == .local { serverText = LocalServer.address }
            #endif
            if try AppEnvironment.store.load().active_server != nil { dismissSetupGuide() }
        } catch { errorMessage = error.localizedDescription }
        scheduleValidation()
    }

    func serverChanged() {
        serverReachable = false
        sidebarStatus = nil
        validation?.cancel(); busy = false; serverError = nil; tokenError = nil
        // A changed destination must not silently receive the previous server’s key.
        server_id = nil
        tokenText = ""
        verifiedServer = nil; verifiedToken = nil; adminDestination = nil
        personas = []; persona = ""; personaError = nil; personasLoaded = false
        serverMessage = nil; tokenMessage = nil; savedMessage = nil; errorMessage = nil
    }
    func tokenChanged() {
        sidebarStatus = nil
        validation?.cancel(); busy = false; tokenError = nil
        personas = []; personaError = nil; personasLoaded = false
        verifiedToken = nil; tokenMessage = nil; savedMessage = nil; errorMessage = nil
    }

    func testServer() async {
        serverReachable = false
        busy = true; errorMessage = nil; savedMessage = nil; serverError = nil
        verifiedServer = nil; verifiedToken = nil; tokenMessage = nil
        personasLoaded = false; personaError = nil
        defer { if !Task.isCancelled { busy = false } }
        do {
            let server = try await client.discoverServer(serverText)
            try Task.checkCancellation()
            let changed = server.absoluteString != serverText
            serverText = server.absoluteString
            verifiedServer = server
            serverReachable = true
            // Remember success without closing a guide reopened during this check.
            UserDefaults.standard.set(true, forKey: "setupGuideDismissed")
            serverMessage = changed ? "Connected. Using \(server.absoluteString)." : "Connected to ArchiveBox."

        } catch { if !Task.isCancelled { serverError = error.localizedDescription } }
    }

    func testToken() async {
        guard let server = verifiedServer else { return }
        busy = true; errorMessage = nil; savedMessage = nil; verifiedToken = nil; tokenError = nil
        defer { if !Task.isCancelled { busy = false } }
        do {
            let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            tokenText = token
            try await client.testToken(server: server, token: token)
            try Task.checkCancellation()
            verifiedToken = token
            tokenMessage = "API key verified."
            // Persist before fetching personas: an unavailable persona endpoint
            // must not lose a valid key when the app closes or is rebuilt.
            do { try persistConnection() }
            catch { errorMessage = error.localizedDescription; return }
            await fetchPersonas(server: server, token: token)
        } catch { if !Task.isCancelled { tokenError = error.localizedDescription } }
    }

    func refreshReachability() async {
        guard let server = verifiedServer else { return }
        do {
            _ = try await client.discoverServer(server.absoluteString)
            try Task.checkCancellation()
            guard verifiedServer == server else { return }
            serverReachable = true
            serverError = nil
        } catch {
            guard !Task.isCancelled, verifiedServer == server else { return }
            serverReachable = false
            serverError = error.localizedDescription
        }
    }

    private func fetchPersonas(server: URL, token: String) async {
        personaError = nil; personasLoaded = false; savedMessage = nil
        do {
            let fetched = try await client.personas(server: server, token: token)
            try Task.checkCancellation()
            guard verifiedServer == server, verifiedToken == token else { return }
            personas = fetched
            personasLoaded = true
        } catch {
            // A failed request says nothing about whether the saved persona exists.
            // Keep the last displayed list, but require a successful refresh before saving it.
            if !Task.isCancelled { personaError = error.localizedDescription }
        }
    }

    func refreshPersonas() async {
        guard let server = verifiedServer, let token = verifiedToken else { return }
        busy = true
        defer { if !Task.isCancelled { busy = false } }
        await fetchPersonas(server: server, token: token)
    }

    func save() {
        guard canSave else { return }
        do {
            try persistConnection()
            savedMessage = "Ready to share. Open a link in any app, tap Share, then choose ArchiveBox."
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func persistConnection() throws {
        guard let server = verifiedServer, let token = verifiedToken, token == tokenText else { return }
        var registry = try AppEnvironment.store.load()
        let existing = registry.servers.first { $0.id == server_id }
            ?? registry.servers.first { $0.server == server }
        let configuration = ServerConfiguration(id: existing?.id ?? UUID().uuidString.lowercased(),
            name: existing?.name ?? "", server: server, token: token, persona: persona.isEmpty ? nil : persona)
        registry.upsert(configuration)
        registry.active_server_id = configuration.id
        registry.default_server_ids = [configuration.id]
        try AppEnvironment.store.save(registry)
        server_id = configuration.id
        ArchiveSystemIndex.connectionChanged()
    }

}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @State private var networkGuide = false
    @State private var discovery = false
    @State private var nearby = ServerDiscovery()
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmingReset = false
    @FocusState private var focusedField: Field?
    private enum Field { case server, token }

    var body: some View {
        Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Label {
                                Text(model.serverReachable ? "Connected" : "Not connected")
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(model.serverReachable ? .green : .red)
                            }
                            .font(.caption.weight(.semibold))
                            .accessibilityLabel(model.serverReachable ? "Server connected" : "Server not connected")
                            Spacer(minLength: 8)
                            if let url = model.displayedBaseURL {
                                Button("Copy URL", systemImage: "doc.on.doc") {
                                    #if os(macOS)
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                    #else
                                    UIPasteboard.general.string = url.absoluteString
                                    #endif
                                }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                Button("Open server", systemImage: "arrow.up.right.square") { model.openAdmin(url) }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                        }
                        // Give addresses the full row: action buttons must not squeeze
                        // a hostname into fragments on phones or at larger text sizes.
                        if let url = model.displayedBaseURL {
                            Text(url.absoluteString)
                                .font(.subheadline.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("configuredBaseURL")
                        } else {
                            Text("No server configured").foregroundStyle(.secondary)
                        }
                    }
                }
                #if os(macOS)
                Section {
                    Picker("Connection", selection: Binding(get: { model.connectionMode }, set: { model.selectConnection($0) })) {
                        Text("Run Server Locally").tag(SettingsModel.ConnectionMode.local)
                        Text("Connect to remote server").tag(SettingsModel.ConnectionMode.remote)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.localServer.busy)
                }
                if model.connectionMode == .local { LocalServerSection(model: model) }
                #endif

                if showRemoteFields {
                    Section {
                        nearbyServers
                        TextField("Server URL", text: Binding(get: { model.serverText }, set: {
                            model.serverChanged(); model.serverText = $0; model.scheduleValidation()
                        }), prompt: Text("https://archivebox.example.com"), axis: .vertical)
                        #if os(iOS)
                        .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                        #endif
                        .lineLimit(1...3)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled().focused($focusedField, equals: .server)
                        .accessibilityIdentifier("serverURL")
                        HStack(alignment: .firstTextBaseline) {
                            if let message = model.serverMessage { status(message).font(.subheadline) }
                            else if model.busy {
                                VStack(alignment: .leading) {
                                    Text("Checking server…")
                                    StartupProgressView()
                                }
                            }
                            Spacer(minLength: 12)
                            Button("Admin") { model.openAdmin(model.adminURL) }
                                .buttonStyle(.borderless)
                                .disabled(model.adminURL == nil).accessibilityIdentifier("openAdmin")
                        }
                        if let error = model.serverError { Text(error).foregroundStyle(.red) }
                    } header: { Text("Server") } footer: {
                        Text("Paste the web address of your ArchiveBox server, not archivebox.io. The connection is checked automatically. Requires ArchiveBox 0.9 or later. Use http:// if your server doesn’t use HTTPS.")
                    }
                }
                Section {
                    SecureField("API key", text: Binding(get: { model.tokenText }, set: {
                        model.tokenChanged(); model.tokenText = $0; model.scheduleValidation()
                    }), prompt: Text("Paste your API key"))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled().focused($focusedField, equals: .token)
                    .accessibilityIdentifier("apiKey")
                    HStack(alignment: .firstTextBaseline) {
                        if let message = model.tokenMessage { status(message).font(.subheadline) }
                        Spacer(minLength: 12)
                        Button("Get Key") { model.openAdmin(model.apiKeysURL) }
                            .buttonStyle(.borderless)
                            .disabled(model.apiKeysURL == nil).accessibilityIdentifier("getAPIKey")
                    }
                    if let error = model.tokenError { Text(error).foregroundStyle(.red) }
                } header: { Text("API key") } footer: {
                    Text("An API key gives this app access to your archive. After connecting, choose Get Key, sign in to your server, create a key, and paste it here. Your key is checked and saved automatically.")
                }


                if let message = model.errorMessage {
                    Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red).accessibilityIdentifier("settingsError") }
                }
                if let message = model.savedMessage {
                    Section { status(message).accessibilityIdentifier("savedConnection") }
                }

                Section {
                    Button("Setup guide & server options", systemImage: "book") { model.showsSetupGuide = true }
                        .accessibilityIdentifier("setup.reopen")
                    Button("Find a server", systemImage: "network") { discovery = true }
                        .accessibilityIdentifier("network.discover")
                    Button("Tailscale & network guide", systemImage: "network.badge.shield.half.filled") { networkGuide = true }
                        .accessibilityIdentifier("network.guide")
                }
                Section {
                    Button("Reset app setup…", role: .destructive) { confirmingReset = true }
                        .accessibilityIdentifier("setup.reset")
                } footer: {
                    Text("Remove saved connections from this device and start again. Archived pages and server accounts are kept.")
                }

            }
            .formStyle(.grouped)
            .scrollDismissesKeyboard(.immediately)
            .onSubmit { focusedField = nil }
            .navigationTitle("Connection Settings")
            .sheet(isPresented: $networkGuide) { TailscaleGuide(role: .client, connect: model.useDiscoveredServer) }
            .sheet(isPresented: $discovery) { ServerDiscoveryView(select: model.useDiscoveredServer) }
            .confirmationDialog("Reset this app’s setup?", isPresented: $confirmingReset) {
                Button("Reset setup", role: .destructive) { model.resetSetup() }
            } message: {
                Text("Saved server addresses and API keys will be removed from this device, including its sharing extensions. Your archive files and server accounts will stay intact.")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") { focusedField = nil; model.save() }
                        .buttonStyle(.glassProminent).disabled(!model.canSave)
                        .accessibilityIdentifier("saveConnection")
                }
                ToolbarItem(placement: .status) {
                    if model.busy {
                        VStack(alignment: .leading) {
                            Text("Testing connection…")
                            StartupProgressView()
                        }
                    }
                }
            }
            .task { model.load(); startDiscovery() }
            .onDisappear { nearby.stop() }
            .onChange(of: showRemoteFields) { startDiscovery() }
            .onChange(of: discovery) { startDiscovery() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { startDiscovery() }
                else if phase == .background { nearby.stop() }
            }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private var showRemoteFields: Bool {
        #if os(macOS)
        model.connectionMode == .remote
        #else
        true
        #endif
    }

    private func startDiscovery() {
        if showRemoteFields && !discovery { nearby.start() }
        else { nearby.stop() }
    }

    private var nearbyServers: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Available servers", systemImage: "network")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("discovery.inline.heading")
                Spacer()
                if nearby.running { ProgressView().controlSize(.small) }
                Button("Search again", systemImage: "arrow.clockwise") { nearby.start() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .accessibilityIdentifier("discovery.inline.refresh")
            }
            if nearby.results.isEmpty {
                Text(nearby.running ? "Looking for ArchiveBox servers…" : "No servers found yet. Check that your server is running and Local Network access is allowed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(nearby.results) { found in
                            Button {
                                focusedField = nil
                                if (try? ServerAddress.normalize(model.serverText)) != found.url {
                                    model.useDiscoveredServer(found.url)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "externaldrive.connected.to.line.below")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(found.source).font(.subheadline)
                                        Text(found.url.absoluteString).font(.caption.monospaced())
                                            .foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: (try? ServerAddress.normalize(model.serverText)) == found.url ? "checkmark.circle.fill" : "chevron.right")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("discovery.inline.result")
                        }
                    }
                }
                .frame(height: min(CGFloat(nearby.results.count) * 62, 186))
            }
            Text("Choose a server, or enter its address below.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }

    private func status(_ message: String) -> some View {
        Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    }
}
