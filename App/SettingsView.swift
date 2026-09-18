import ArchiveBoxCore
import SwiftUI

@MainActor @Observable
final class SettingsModel {
    var adminDestination: URL?
    var adminNavigationID = UUID()
    func openAdmin(_ url: URL?) {
        guard let url else { return }
        adminDestination = url; adminNavigationID = UUID()
    }

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

    func selectConnection(_ mode: ConnectionMode) {
        guard mode != connectionMode else { return }
        do {
            // Preserve the last saved remote connection before selecting the local
            // profile. Never persist an untested draft as working credentials.
            if let active = try AppEnvironment.store.load() {
                try AppEnvironment.configurationStore(account: "profile-\(connectionMode.rawValue)").save(active)
            }
            let config = try AppEnvironment.configurationStore(account: "profile-\(mode.rawValue)").load()
            serverChanged()
            connectionMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "connectionMode")
            serverText = config?.server.absoluteString ?? (mode == .local ? LocalServer.address : "")
            tokenText = config?.token ?? ""; persona = config?.persona ?? ""
            // Prevent sharing to the previously selected profile while setting up
            // the new one. The profile itself remains safely stored in Keychain.
            try AppEnvironment.store.clear()
            if let config {
                try AppEnvironment.store.save(config)
                savedMessage = "Saved connection restored for sharing. Checking server connection…"
            }
        } catch { errorMessage = error.localizedDescription }
        scheduleValidation()
    }

    func localServerReady(_ server: URL) async throws {
        serverText = server.absoluteString; verifiedServer = server
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
            let config = try AppEnvironment.configurationStore(account: "profile-\(connectionMode.rawValue)").load()
            #else
            let config = try AppEnvironment.store.load()
            #endif
            if let config {
                serverText = config.server.absoluteString
                tokenText = config.token
                persona = config.persona ?? ""
                savedMessage = "Your saved connection is ready for the share sheet."
            }
            #if os(macOS)
            if config == nil && connectionMode == .local { serverText = LocalServer.address }
            #endif
        } catch { errorMessage = error.localizedDescription }
        scheduleValidation()
    }

    func serverChanged() {
        sidebarStatus = nil
        validation?.cancel(); busy = false; serverError = nil; tokenError = nil
        // A changed destination must not silently receive the previous server’s key.
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
        let configuration = ServerConfiguration(server: server, token: token, persona: persona.isEmpty ? nil : persona)
        #if os(macOS)
        try AppEnvironment.configurationStore(account: "profile-\(connectionMode.rawValue)").save(configuration)
        #endif
        try AppEnvironment.store.save(configuration)
    }

}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @FocusState private var focusedField: Field?
    private enum Field { case server, token }

    var body: some View {
        Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Label {
                                Text(model.verifiedServer == nil ? "Not connected" : "Connected")
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(model.verifiedServer == nil ? .red : .green)
                            }
                            .font(.caption.weight(.semibold))
                            .accessibilityLabel(model.verifiedServer == nil ? "Server not connected" : "Server connected")
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
                            else if model.busy { ProgressView("Checking server…").controlSize(.small) }
                            Spacer(minLength: 12)
                            Button("Admin") { model.openAdmin(model.adminURL) }
                                .buttonStyle(.borderless)
                                .disabled(model.adminURL == nil).accessibilityIdentifier("openAdmin")
                        }
                        if let error = model.serverError { Text(error).foregroundStyle(.red) }
                    } header: { Text("Server") } footer: {
                        Text("Paste your server URL; the connection is checked automatically. Requires ArchiveBox 0.9 or later. Use http:// if your server doesn’t use HTTPS.")
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
                    Text("Use Get Key to create a key on your server. Your key is checked and saved automatically.")
                }


                if let message = model.errorMessage {
                    Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red).accessibilityIdentifier("settingsError") }
                }
                if let message = model.savedMessage {
                    Section { status(message).accessibilityIdentifier("savedConnection") }
                }

            }
            .formStyle(.grouped)
            .scrollDismissesKeyboard(.immediately)
            .onSubmit { focusedField = nil }
            .navigationTitle("Connection Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") { focusedField = nil; model.save() }
                        .buttonStyle(.glassProminent).disabled(!model.canSave)
                        .accessibilityIdentifier("saveConnection")
                }
                ToolbarItem(placement: .status) {
                    if model.busy { ProgressView("Testing connection…") }
                }
            }
            .task { model.load() }
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

    private func status(_ message: String) -> some View {
        Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    }
}
