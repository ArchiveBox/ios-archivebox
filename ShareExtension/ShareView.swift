import ArchiveBoxCore
import SwiftUI

struct ShareView: View {
    @Bindable var model: ShareModel
    let finish: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView("Reading shared link…")
                case .sent(let count):
                    ContentUnavailableView {
                        Label("Sent to ArchiveBox", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text(count == 1 ? "Your server accepted the link for archiving." : "Your server accepted \(count) links for archiving.")
                    } actions: {
                        Button("Done", action: finish).buttonStyle(.glassProminent)
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn’t save link", systemImage: "exclamationmark.circle")
                    } description: { Text(message) } actions: {
                        Button("Close", action: finish).buttonStyle(.glass)
                    }
                case .ready, .sending:
                    Form {
                        Section("Link\(model.urls.count == 1 ? "" : "s")") {
                            ForEach(model.urls, id: \.absoluteString) { url in
                                Text(url.absoluteString).textSelection(.enabled)
                            }
                        }
                        Section("Save to") {
                            Label(model.configuration?.server.absoluteString ?? "ArchiveBox", systemImage: "server.rack")
                            Label(model.configuration?.persona ?? "Server default", systemImage: "person.crop.circle")
                        }
                        Section {
                            if model.state == .sending { ProgressView("Sending to your server…") }
                            else {
                                Button { Task { await model.submit() } } label: {
                                    Label("Save to ArchiveBox", systemImage: "archivebox")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glassProminent).controlSize(.large)
                                .accessibilityIdentifier("submitShare")
                            }
                        } footer: { Text("Keep this sheet open until your server confirms.") }
                    }
                    .formStyle(.grouped)
                }
            }
            .navigationTitle("ArchiveBox")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if model.state == .ready || model.state == .loading {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: finish) }
                }
            }
            #if os(macOS)
            .safeAreaInset(edge: .bottom) {
                if model.state == .ready || model.state == .loading {
                    HStack { Button("Cancel", action: finish).keyboardShortcut(.cancelAction); Spacer() }
                        .padding()
                }
            }
            #endif
            .interactiveDismissDisabled(model.state == .sending)
        }
        .tint(Color("AccentColor"))
    }
}
