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
            if mode == .remote, let config {
                try AppEnvironment.store.save(config)
                savedMessage = "Remote connection restored for sharing. Checking server connection…"
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
            let profile = try AppEnvironment.configurationStore(account: "profile-\(connectionMode.rawValue)").load()
            // Only the remote profile predates connection modes. A new local
            // profile must never inherit a remote server's URL or API key.
            let config = try profile ?? (connectionMode == .remote ? AppEnvironment.store.load() : nil)
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
        validation?.cancel(); busy = false; serverError = nil; tokenError = nil
        // A changed destination must not silently receive the previous server’s key.
        tokenText = ""
        verifiedServer = nil; verifiedToken = nil; adminDestination = nil
        personas = []; persona = ""; personaError = nil; personasLoaded = false
        serverMessage = nil; tokenMessage = nil; savedMessage = nil; errorMessage = nil
    }
    func tokenChanged() {
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
        guard canSave, let server = verifiedServer else { return }
        do {
            try AppEnvironment.store.save(ServerConfiguration(server: server, token: tokenText, persona: persona.isEmpty ? nil : persona))
            #if os(macOS)
            try AppEnvironment.configurationStore(account: "profile-\(connectionMode.rawValue)").save(ServerConfiguration(server: server, token: tokenText, persona: persona.isEmpty ? nil : persona))
            #endif
            savedMessage = "Ready to share. Open a link in any app, tap Share, then choose ArchiveBox."
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @FocusState private var focusedField: Field?
    private enum Field { case server, token }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let url = model.displayedBaseURL {
                            Text(url.absoluteString).textSelection(.enabled)
                                .accessibilityIdentifier("configuredBaseURL")
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
                        } else {
                            Text("No server configured").foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(model.verifiedServer == nil ? "🔴 NOT CONNECTED" : "🟢 CONNECTED")
                            .font(.caption.weight(.semibold))
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
                        HStack {
                            TextField("Server URL", text: Binding(get: { model.serverText }, set: {
                                model.serverChanged(); model.serverText = $0; model.scheduleValidation()
                            }), prompt: Text("https://archivebox.example.com"))
                            #if os(iOS)
                            .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled().focused($focusedField, equals: .server)
                            .accessibilityIdentifier("serverURL")
                            if model.verifiedServer != nil { Text("🟢").accessibilityLabel("Server connected") }
                            else if model.serverError != nil { Text("🔴").accessibilityLabel("Server unreachable") }
                            else if model.busy { ProgressView().controlSize(.small) }
                            Button("Admin") { model.openAdmin(model.adminURL) }
                                .disabled(model.adminURL == nil).accessibilityIdentifier("openAdmin")
                        }
                        if let message = model.serverMessage { status(message) }
                        if let error = model.serverError { Text(error).foregroundStyle(.red) }
                    } header: { Text("Server") } footer: {
                        Text("ArchiveBox 0.9 or later. Your address is checked automatically. Paste a server or admin URL; we’ll find its API address. Include http:// for a server without HTTPS.")
                    }
                }
                Section {
                    HStack {
                        SecureField("API key", text: Binding(get: { model.tokenText }, set: {
                            model.tokenChanged(); model.tokenText = $0; model.scheduleValidation()
                        }))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled().focused($focusedField, equals: .token)
                        .accessibilityIdentifier("apiKey")
                        if model.verifiedToken != nil { Text("🟢").accessibilityLabel("API key verified") }
                        else if model.tokenError != nil { Text("🔴").accessibilityLabel("API key rejected") }
                        Button("Get Key") { model.openAdmin(model.apiKeysURL) }
                            .disabled(model.apiKeysURL == nil).accessibilityIdentifier("getAPIKey")
                    }
                    if let message = model.tokenMessage { status(message) }
                    if let error = model.tokenError { Text(error).foregroundStyle(.red) }
                } header: { Text("API key") } footer: {
                    Text("Get an administrator API key from your server. It is checked automatically and saved securely in Keychain when you choose Save.")
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

    private func status(_ message: String) -> some View {
        Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    }
}
