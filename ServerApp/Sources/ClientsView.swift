import AppKit
import ArchiveBoxCore
import SwiftUI

struct ClientsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clients").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ClientAppSection(model: model)
            BrowserExtensionSetup(title: "ArchiveBox Browser Extension")
        }
    }
}

struct ClientAppSection: View {
    @ObservedObject var model: SettingsModel
    var dismissSuggestion: (() -> Void)?
    @Environment(\.openURL) private var openURL
    @State private var installedClient = AppInformation.installedClientURL
    @State private var launchError: String?
    @State private var opening = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image("BrandLogo").resizable().scaledToFit().frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dismissSuggestion == nil ? "ArchiveBox.app" : "Your server is ready")
                            .font(.headline)
                        Text("Save links from other apps, browse your archive, and use the Safari extension with ArchiveBox.app.")
                            .foregroundStyle(.secondary)
                    }
                }
                if installedClient == nil {
                    Text("Download the Mac app, unzip it, and drag ArchiveBox.app to Applications. Then return here to connect it to your server.")
                    HStack {
                        Button("Download ArchiveBox.app for Mac", systemImage: "arrow.down.circle") {
                            openURL(URL(string: "https://github.com/ArchiveBox/ios-archivebox/releases/latest/download/ArchiveBox.app.zip")!)
                        }.accessibilityIdentifier("client.download")
                        Button("Check again", systemImage: "arrow.clockwise") { refreshClient() }
                            .accessibilityIdentifier("client.check")
                    }
                } else {
                    Label("ArchiveBox.app is installed on this Mac", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                    Button("Open & Connect ArchiveBox.app", systemImage: "desktopcomputer") { connectClient() }
                        .disabled(!model.healthy || !model.hasAdmin || model.changingCollection || model.managementBusy || opening)
                        .accessibilityIdentifier("client.connect")
                    Text("Connects the app to this server with your administrator account.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Link("Get the iPhone / iPad app", destination: URL(string: "https://testflight.apple.com/join/wUG6DS6z")!)
                    Spacer()
                    if let dismissSuggestion {
                        Button("Not now", action: dismissSuggestion)
                            .accessibilityIdentifier("client.dismiss")
                    }
                }
                if dismissSuggestion != nil {
                    Text("You can also use the web interface. App downloads and connection help are always in Clients.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let launchError { Text(launchError).foregroundStyle(.red).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .buttonStyle(.bordered)
        }
        .onAppear { refreshClient() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshClient() }
    }

    private func refreshClient() {
        installedClient = AppInformation.installedClientURL
        launchError = nil
    }

    private func connectClient() {
        refreshClient()
        guard let app = installedClient, model.healthy, model.hasAdmin, !model.changingCollection,
              let server = model.serverDetails?.api, let key = model.qrAPIKey else {
            launchError = "The app or server connection is not ready. Check again once both are available."
            return
        }
        opening = true
        // Send credentials only to the detected client, never to a download page or clipboard.
        NSWorkspace.shared.open([ConnectionLink.make(server: server, apiKey: key)], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in
                opening = false
                launchError = error?.localizedDescription
                if error == nil { dismissSuggestion?() }
            }
        }
    }
}
