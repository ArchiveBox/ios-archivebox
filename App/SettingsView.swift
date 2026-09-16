import ArchiveBoxCore
import SwiftUI

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
    var busy = false
    private let client = ArchiveBoxClient()

    var canSave: Bool {
        verifiedServer != nil && verifiedToken == tokenText && !tokenText.isEmpty && !busy
    }

    func load() {
        do {
            if let config = try AppEnvironment.store.load() {
                serverText = config.server.absoluteString
                tokenText = config.token
                savedMessage = "Your saved connection is ready for the share sheet."
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func serverChanged() {
        verifiedServer = nil; verifiedToken = nil
        serverMessage = nil; tokenMessage = nil; savedMessage = nil; errorMessage = nil
    }
    func tokenChanged() {
        verifiedToken = nil; tokenMessage = nil; savedMessage = nil; errorMessage = nil
    }

    func testServer() async {
        busy = true; errorMessage = nil; savedMessage = nil
        verifiedServer = nil; verifiedToken = nil; tokenMessage = nil
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
        } catch { errorMessage = error.localizedDescription }
    }

    func save() {
        guard canSave, let server = verifiedServer else { return }
        do {
            try AppEnvironment.store.save(ServerConfiguration(server: server, token: tokenText))
            savedMessage = "Ready to share. Open a link in any app, tap Share, then choose ArchiveBox."
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

struct SettingsView: View {
    @State private var model = SettingsModel()
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

                Section {
                    TextField("https://archivebox.example.com", text: Binding(
                        get: { model.serverText },
                        set: { model.serverChanged(); model.serverText = $0 }
                    ))
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
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
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
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

                if let message = model.errorMessage {
                    Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red).accessibilityIdentifier("settingsError") }
                }
                if let message = model.savedMessage {
                    Section { status(message).accessibilityIdentifier("savedConnection") }
                }
                Section {
                    Label("Links are sent directly to your server.", systemImage: "arrow.up.right")
                        .foregroundStyle(.secondary)
                    Text("Keep the share sheet open until the server confirms. If your server is on a private network, connect to its Wi-Fi or VPN first.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("ArchiveBox")
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
    }

    private func status(_ message: String) -> some View {
        Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    }
}
