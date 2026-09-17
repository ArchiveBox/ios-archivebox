import ArchiveBoxCore
import SwiftUI
import SafariServices

@MainActor @Observable
final class SettingsModel {
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
                savedMessage = "Remote connection restored for sharing. Test server to open Archive."
            }
        } catch { errorMessage = error.localizedDescription }
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
    }

    func serverChanged() {
        verifiedServer = nil; verifiedToken = nil
        personas = []; persona = ""; personaError = nil; personasLoaded = false
        serverMessage = nil; tokenMessage = nil; savedMessage = nil; errorMessage = nil
    }
    func tokenChanged() {
        personas = []; personaError = nil; personasLoaded = false
        verifiedToken = nil; tokenMessage = nil; savedMessage = nil; errorMessage = nil
    }

    func testServer() async {
        busy = true; errorMessage = nil; savedMessage = nil
        verifiedServer = nil; verifiedToken = nil; tokenMessage = nil
        personasLoaded = false; personaError = nil
        defer { busy = false }
        do {
            let server = try await client.discoverServer(serverText)
            let changed = server.absoluteString != serverText
            serverText = server.absoluteString
            verifiedServer = server
            serverMessage = changed ? "Connected. Using \(server.absoluteString)." : "Connected to ArchiveBox."
        } catch { errorMessage = error.localizedDescription }
    }

    func testToken() async {
        guard let server = verifiedServer else { return }
        busy = true; errorMessage = nil; savedMessage = nil; verifiedToken = nil
        defer { busy = false }
        do {
            let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            tokenText = token
            try await client.testToken(server: server, token: token)
            verifiedToken = token
            tokenMessage = "API key verified."
            await fetchPersonas(server: server, token: token)
        } catch { errorMessage = error.localizedDescription }
    }

    private func fetchPersonas(server: URL, token: String) async {
        personaError = nil; personasLoaded = false; savedMessage = nil
        do {
            personas = try await client.personas(server: server, token: token)
            personasLoaded = true
        } catch {
            // A failed request says nothing about whether the saved persona exists.
            // Keep the last displayed list, but require a successful refresh before saving it.
            personaError = error.localizedDescription
        }
    }

    func refreshPersonas() async {
        guard let server = verifiedServer, let token = verifiedToken else { return }
        busy = true
        defer { busy = false }
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
    @Environment(\.openURL) private var openURL
    @FocusState private var focusedField: Field?
    private enum Field { case server, token }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image("BrandLogo")
                            .resizable().scaledToFit().frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .accessibilityHidden(true)
                        Text("Your web, preserved.").font(.title2.bold())
                        Text("Connect your ArchiveBox server, then save links from the share sheet in any app.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                #if os(macOS)
                LocalServerSection(model: model)
                #endif

                Section {
                    TextField("Server URL", text: Binding(
                        get: { model.serverText },
                        set: { model.serverChanged(); model.serverText = $0 }
                    ), prompt: Text("https://archivebox.example.com"))
                        #if os(iOS)
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        #if os(macOS)
                        .disabled(model.connectionMode == .local)
                        #endif
                        .focused($focusedField, equals: .server)
                        .accessibilityLabel("Server URL").accessibilityIdentifier("serverURL")
                    Button {
                        focusedField = nil
                        Task { await model.testServer() }
                    } label: { Label("Test server", systemImage: "network") }
                        .disabled(model.busy || model.serverText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("testServer")
                    if let message = model.serverMessage { status(message) }
                } header: { Text("Server") } footer: {
                    Text("ArchiveBox 0.9 or later. Paste your server or admin address; we’ll find its API address. Include http:// for a server without HTTPS.")
                }

                Section {
                    SecureField("API key", text: Binding(
                        get: { model.tokenText },
                        set: { model.tokenChanged(); model.tokenText = $0 }
                    ))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .token)
                        .accessibilityIdentifier("apiKey")
                    Button {
                        focusedField = nil
                        Task { await model.testToken() }
                    } label: { Label("Test API key", systemImage: "key") }
                        .disabled(model.busy || model.verifiedServer == nil || model.tokenText.isEmpty)
                        .accessibilityIdentifier("testAPIKey")
                    if let message = model.tokenMessage { status(message) }
                } header: { Text("API key") } footer: {
                    Text("Create an API key in your server’s admin settings under API Tokens. Test the server first. Your key is stored securely in Keychain.")
                }

                Section {
                    Picker("Default persona", selection: Binding(get: { model.persona }, set: { model.persona = $0; model.savedMessage = nil })) {
                        Text("Server default").tag("")
                        ForEach(model.personas) { persona in Text(persona.name).tag(persona.name) }
                        if !model.persona.isEmpty && !model.personas.contains(where: { $0.name == model.persona }) {
                            Text(model.personasLoaded ? "\(model.persona) (not found on server)" : model.persona).tag(model.persona)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("defaultPersona")
                    .disabled(model.verifiedToken == nil)
                    Button("Refresh personas", systemImage: "arrow.clockwise") {
                        Task { await model.refreshPersonas() }
                    }
                    .disabled(model.verifiedToken == nil || model.busy)
                    if let message = model.personaError {
                        Text("Couldn’t refresh personas: \(message) Your saved persona has not changed.").foregroundStyle(.red)
                    }
                } header: { Text("Archiving") } footer: {
                    Text("Test your API key to load personas from the server. Shared links use your saved choice. Server default uses the server’s Default persona.")
                }

                if let message = model.errorMessage {
                    Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red).accessibilityIdentifier("settingsError") }
                }
                if let message = model.savedMessage {
                    Section { status(message).accessibilityIdentifier("savedConnection") }
                }
                Section("Browser Extension") {
                    Text("Choose your browser to set up ArchiveBox: enable the bundled Safari extension, or install it from the Chrome, Brave, or Firefox extension store.")
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
                            ForEach([("Chrome", "Chrome", "https://chromewebstore.google.com/detail/archivebox/habonpimjphpdnmcfkaockjnffodikoj"),
                                     ("Brave", "Brave", "https://chromewebstore.google.com/detail/archivebox/habonpimjphpdnmcfkaockjnffodikoj"),
                                     ("Firefox", "Firefox", "https://addons.mozilla.org/firefox/addon/archivebox-exporter/"),
                                     ("Source Code", "GitHubMark", "https://github.com/ArchiveBox/archivebox-browser-extension")], id: \.0) { name, icon, address in
                                Button { openURL(URL(string: address)!) } label: {
                                    Label { Text(name) } icon: {
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
                    Text("Safari automatically uses the connection saved here. For Chrome, Brave, and Firefox, enter your server URL and API key in the extension. Brave uses the Chrome Web Store.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Label("Links are sent directly to your server.", systemImage: "arrow.up.right")
                        .foregroundStyle(.secondary)
                    Text("Keep the share sheet open until the server confirms. If your server is on a private network, connect to its Wi-Fi or VPN first.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
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
            .disabled(model.busy)
            .task { model.load() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func status(_ message: String) -> some View {
        Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    }
}
