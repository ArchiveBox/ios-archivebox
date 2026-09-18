#if os(macOS)
import SwiftUI
import AppKit
import ArchiveBoxCore

struct LocalServerSection: View {
    @Bindable var model: SettingsModel
    var body: some View {
        Section("ArchiveBox Server on this Mac") {
            if let server = model.verifiedServer, model.serverReachable {
                HStack {
                    Text("🟢 Running: port \(String(server.port ?? (server.scheme == "https" ? 443 : 80)))")
                    Spacer()
                    Button("Open ArchiveBox Server.app › Settings") {
                        if let app = model.localServer.installedApp { NSWorkspace.shared.open(app) }
                    }.disabled(model.localServer.installedApp == nil)
                }
            } else if model.localServer.installedApp != nil {
                Text(model.serverError == nil ? "Checking local server…" : "🔴 Server not connected")
                Button("Start ArchiveBox Server.app", systemImage: "power") { model.localServer.launch(settings: model) }
                    .disabled(model.localServer.busy)
            } else {
                Button("Download ArchiveBox Server.app…", systemImage: "arrow.down.app") { model.localServer.launch(settings: model) }
                    .disabled(model.localServer.busy)
            }
            if model.localServer.busy {
                Text(model.localServer.message).foregroundStyle(.secondary)
                StartupProgressView(progress: model.localServer.progress)
                Button("Cancel") { model.localServer.cancel() }
            }
            Text("ArchiveBox Server runs in the menu bar and keeps your archive on this Mac. Open its Settings to create an administrator, then use Get Key below to configure sharing. Closing this app does not stop the server.")
                .foregroundStyle(.secondary)
            if let error = model.localServer.error ?? model.serverError { Text(error).foregroundStyle(.red) }
        }
    }
}
#endif
