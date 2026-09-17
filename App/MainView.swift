import SafariServices
import SwiftUI
import WebKit

struct MainView: View {
    @Bindable var settings: SettingsModel
    @State private var selection = Screen.settings
    private enum Screen { case add, archive, admin, settings }

    var body: some View {
        let server = settings.verifiedServer
        TabView(
            selection: Binding(
                get: { selection },
                set: {
                    if $0 == .settings || $0 == .add || server != nil || ($0 == .admin && settings.adminDestination != nil) { selection = $0 }
                })
        ) {
            Tab("Add URLs", systemImage: "plus", value: .add) { AddURLsView(model: settings) }
            Tab("Archive", systemImage: "building.columns", value: .archive) {
                NavigationStack {
                    if let server { ServerWebView(url: server.appending(path: "admin/core/snapshot/grid/"), title: "Archive").id(server) }
                }
            }.disabled(server == nil)
            Tab("Admin", systemImage: "person.crop.circle", value: .admin) {
                NavigationStack {
                    if let destination = settings.adminDestination ?? settings.adminURL {
                        ServerWebView(url: destination, title: "Admin").id("\(destination)-\(settings.adminNavigationID)")
                    }
                }
            }.disabled(server == nil && settings.adminDestination == nil)
            Tab("Connection Settings", systemImage: "gearshape", value: .settings) { SettingsView(model: settings) }
        }
        .tabViewStyle(.sidebarAdaptable)
        .task { settings.load() }
        .onChange(of: settings.adminNavigationID) { selection = .admin }
        .onChange(of: settings.verifiedServer) {
            if settings.verifiedServer == nil && selection != .add { selection = .settings }
        }
    }
}

// WebPage uses WebKit's persistent cookie store, shared by the three web screens.
// The native API key never enters web content; normal server login handles sessions.
private struct ServerWebView: View {
    let url: URL
    let title: String
    @State private var page: WebPage = {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .default()
        // The server's Add template includes Django base.css (980px minimum)
        // without responsive.css. Load its own responsive rules inside this embed
        // and release the desktop width constraint; do not hide overflowing fields.
        configuration.userContentController.addUserScript(WKUserScript(source: #"""
        if (document.querySelector('.add-page')) {
            const base = document.querySelector('link[href*="admin/css/base.css"]');
            if (base && !document.querySelector('link[href*="admin/css/responsive.css"]')) {
                const responsive = document.createElement('link');
                responsive.rel = 'stylesheet';
                responsive.href = base.href.replace('admin/css/base.css', 'admin/css/responsive.css');
                document.head.append(responsive);
            }
            const style = document.createElement('style');
            style.textContent = `#container { min-width: 0; width: 100%; }
                #content { min-width: 0; max-width: 100%; box-sizing: border-box; }
                #header { min-width: 0; flex-wrap: wrap; gap: 12px; }
                #header a { white-space: normal; overflow-wrap: anywhere; }`;
            document.head.append(style);
        }
        """#, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        return WebPage(configuration: configuration)
    }()
    @State private var errorMessage: String?
    var body: some View {
        WebView(page)
            .overlay {
                if let errorMessage {
                    ContentUnavailableView {
                        Label("Couldn’t open \(title)", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") { Task { await load() } }.buttonStyle(.glass)
                    }.background(.background)
                }
            }
            .navigationTitle(title)
            // Returning from a successful login in another pane should not leave a
            // previously visited pane stranded on its cached login form.
            .task { if page.url == nil || page.url?.path.contains("/login/") == true { await load() } }
    }
    private func load() async {
        errorMessage = nil
        do { for try await _ in page.load(url) {} } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
}

private struct AddURLsView: View {
    @Bindable var model: SettingsModel
    @Environment(\.openURL) private var openURL
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let server = model.verifiedServer {
                        ServerWebView(url: server.appending(path: "add/"), title: "Add URLs")
                            .id(server).frame(maxWidth: .infinity).frame(height: 580)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        ContentUnavailableView("Connect your server", systemImage: "network", description: Text("Set up Connection Settings to use the embedded Add URLs form."))
                    }
                    Text("More ways to add").font(.title2.bold())
                    Text("There are several ways you can add new URLs to archive.")
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("In any app, open Share → ArchiveBox (under More if needed) → Save to ArchiveBox, and keep the sheet open until it finishes.")
                            Image("ShareSheetGuide").resizable().scaledToFit().frame(maxHeight: 320)
                                .accessibilityLabel("iPhone share sheet with ArchiveBox available in the Apps list")
                            Picker(
                                "Default persona",
                                selection: Binding(
                                    get: { model.persona },
                                    set: {
                                        model.persona = $0
                                        model.save()
                                    })
                            ) {
                                Text("Server default").tag("")
                                ForEach(model.personas) { persona in Text(persona.name).tag(persona.name) }
                                if !model.persona.isEmpty && !model.personas.contains(where: { $0.name == model.persona }) {
                                    Text(model.personasLoaded ? "\(model.persona) (not found on server)" : model.persona).tag(model.persona)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("defaultPersona")
                            .disabled(model.verifiedToken == nil || model.busy)
                            Button("Refresh personas", systemImage: "arrow.clockwise") {
                                Task { await model.refreshPersonas() }
                            }
                            .disabled(model.verifiedToken == nil || model.busy)
                            if let message = model.personaError {
                                Text("Couldn’t refresh personas: \(message) Your saved persona has not changed.").foregroundStyle(.red)
                            }

                            Text("Default Persona applies to native share-sheet saves. Browser extensions and the web form have their own persona controls.").font(.footnote)
                                .foregroundStyle(.secondary)
                            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("Share Sheet", systemImage: "square.and.arrow.up")
                    }
                    GroupBox("Browser Extension") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(
                                "Import browser bookmarks or history, save URLs by clicking the extension icon, and include cookies for authenticated pages. Choose your browser to install or enable ArchiveBox."
                            )
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
                                    ForEach(
                                        [
                                            ("Chrome", "Chrome", "https://chromewebstore.google.com/detail/archivebox/habonpimjphpdnmcfkaockjnffodikoj"),
                                            ("Brave", "Brave", "https://chromewebstore.google.com/detail/archivebox/habonpimjphpdnmcfkaockjnffodikoj"),
                                            ("Firefox", "Firefox", "https://addons.mozilla.org/firefox/addon/archivebox-exporter/"),
                                            ("Source Code", "GitHubMark", "https://github.com/ArchiveBox/archivebox-browser-extension"),
                                        ], id: \.0
                                    ) { name, icon, address in
                                        Button {
                                            openURL(URL(string: address)!)
                                        } label: {
                                            Label {
                                                Text(name)
                                            } icon: {
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
                            Text(
                                "Safari automatically uses the connection saved here. For Chrome, Brave, and Firefox, enter your server URL and API key in the extension. Brave uses the Chrome Web Store."
                            )
                            .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    GroupBox("And more…") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(
                                [
                                    ("REST API", "https://github.com/ArchiveBox/ArchiveBox/issues/496#issuecomment-2080174235"),
                                    ("Command-line interface", "https://github.com/ArchiveBox/ArchiveBox/wiki/Usage#cli-usage"),
                                    ("SQLite / SQL shell", "https://github.com/ArchiveBox/ArchiveBox/wiki/Usage#sql-shell-usage"),
                                    ("Supported sources", "https://github.com/ArchiveBox/ArchiveBox/wiki/Quickstart#2-get-your-list-of-urls-to-archive"),
                                ], id: \.0
                            ) { title, address in
                                Link(title, destination: URL(string: address)!)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(20).frame(maxWidth: 1000)
            }.navigationTitle("Add URLs")
        }
    }
}
