#if os(macOS)
import SwiftUI
import AppKit

struct LocalServerSection: View {
    @Bindable var model: SettingsModel
    var body: some View {
        Section("Connection") {
            Picker("Server location", selection: Binding(get: { model.connectionMode }, set: { model.selectConnection($0) })) {
                Text("Remote server").tag(SettingsModel.ConnectionMode.remote)
                Text("This Mac").tag(SettingsModel.ConnectionMode.local)
            }
            .disabled(model.localServer.busy)
            if model.connectionMode == .local {
                Text("ArchiveBox Server runs separately in the menu bar and includes the full archiving toolset. Nothing is downloaded until you choose Run server locally.")
                    .foregroundStyle(.secondary)
                if model.localServer.busy {
                    if let progress = model.localServer.progress { ProgressView(value: progress) }
                    else { ProgressView() }
                    Button("Cancel") { model.localServer.cancel() }
                } else {
                    Button("Run server locally", systemImage: "desktopcomputer") { model.localServer.launch(settings: model) }
                        .buttonStyle(.glassProminent)
                    if let app = model.localServer.installedApp {
                        Button("Open ArchiveBox Server", systemImage: "menubar.rectangle") { NSWorkspace.shared.open(app) }
                    }
                }
                Text(model.localServer.message).font(.callout)
                if let error = model.localServer.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
    }
}
#endif
