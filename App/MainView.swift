import SwiftUI
import WebKit

struct MainView: View {
    @Bindable var settings: SettingsModel
    @State private var selection = Screen.settings
    private enum Screen { case settings, archive }

    var body: some View {
        let server = settings.verifiedServer
        TabView(selection: Binding(get: { selection }, set: {
            // Tab disabled state is not enforced by every platform's tab-bar style.
            if $0 == .settings || settings.verifiedServer != nil { selection = $0 }
        })) {
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                SettingsView(model: settings)
            }
            Tab("Archive", systemImage: "building.columns", value: .archive) {
                if let server {
                    ArchiveView(server: server).id(server)
                }
            }
            .disabled(server == nil)
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: settings.verifiedServer) {
            // Editing the connection must not leave an old server visible or selectable.
            if settings.verifiedServer == nil { selection = .settings }
        }
    }
}

private struct ArchiveView: View {
    let server: URL
    @State private var page = WebPage()
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            WebView(page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .webViewBackForwardNavigationGestures(.enabled)
                .overlay {
                    if let errorMessage {
                        ContentUnavailableView {
                            Label("Couldn’t open archive", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(errorMessage)
                        } actions: {
                            Button("Try again") { Task { await load() } }
                                .buttonStyle(.glass)
                        }
                        .background(.background)
                    }
                }
                .navigationTitle("Archive")
                .task {
                    // Keep the current page and login session when switching tabs.
                    if page.url == nil { await load() }
                }
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            // The server redirects /admin/ to its admin host in subdomain mode.
            // Use normal web login/cookies; never inject the API key into web content.
            for try await _ in page.load(server.appending(path: "admin/")) {}
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}
