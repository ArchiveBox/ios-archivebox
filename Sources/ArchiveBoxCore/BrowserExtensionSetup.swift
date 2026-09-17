import SafariServices
import SwiftUI

/// The client and companion offer the same installation guidance and destinations.
/// Browser behavior and the optional app-connection reader live in the WXT repo.
public struct BrowserExtensionSetup: View {
    @Environment(\.openURL) private var openURL
    @State private var errorMessage: String?
    @State private var showSafariSetup = false
    private let title: String
    public init(title: String = "Browser Extension") { self.title = title }

    #if os(macOS)
    @MainActor public static func openSafariSettings(completion: @escaping @MainActor (Error?) -> Void) {
        // Safari requires this call to come from the app that contains the extension.
        // The server companion delegates to that app through its navigation URL.
        if Bundle.main.bundleIdentifier == "io.archivebox.ArchiveBox" {
            SFSafariApplication.showPreferencesForExtension(withIdentifier: "io.archivebox.ArchiveBox.Safari") { error in
                Task { @MainActor in completion(error) }
            }
            return
        }
        let workspace = NSWorkspace.shared
        let app = AppInformation.installedClientURL
        guard let app else {
            completion(NSError(domain: "ArchiveBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "Install ArchiveBox.app first; it contains the Safari extension."]))
            return
        }
        workspace.open([URL(string: "archivebox://safari-extension-settings")!], withApplicationAt: app,
                       configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in completion(error) }
        }
    }
    #endif

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupBox(title) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(
                        "Import browser bookmarks or history, save URLs by clicking the extension icon, and include cookies for authenticated pages. Choose your browser to install or enable ArchiveBox."
                    )
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            #if os(macOS)
                                Button("Safari", systemImage: "safari") {
                                    showSafariSetup = true
                                }
                                .alert("Enable ArchiveBox in Safari", isPresented: $showSafariSetup) {
                                    Button("Cancel", role: .cancel) {}
                                    Button("OK") {
                                        Self.openSafariSettings { error in
                                            if let error { Task { @MainActor in errorMessage = error.localizedDescription } }
                                        }
                                    }
                                } message: {
                                    Text("Open Safari → Settings → Extensions, select ArchiveBox, and enable its checkbox. Choose which websites ArchiveBox can access.\n\nClick OK to open Safari’s extension settings. If it opens on a different page, follow the steps above.")
                                }
                            #else
                                if #available(iOS 26.2, *) {
                                    Button("Safari", systemImage: "safari") {
                                        showSafariSetup = true
                                    }
                                    .alert("Enable ArchiveBox in Safari", isPresented: $showSafariSetup) {
                                        Button("Cancel", role: .cancel) {}
                                        Button("OK") {
                                            SFSafariSettings.openExtensionsSettings(forIdentifiers: ["io.archivebox.ArchiveBox.Safari"]) { error in
                                                if let error { errorMessage = error.localizedDescription }
                                            }
                                        }
                                    } message: {
                                        Text("Open Settings → Apps → Safari → Extensions → ArchiveBox, then turn on Allow Extension. Choose which websites ArchiveBox can access.\n\nTap OK to open Settings. If it opens on a different page, follow the steps above.")
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
                        "Safari can use the connection saved in ArchiveBox.app or its own extension options. For Chrome, Brave, and Firefox, configure the extension directly. Brave uses the Chrome Web Store."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
}
