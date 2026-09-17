import AppKit
import ArchiveBoxCore
import SwiftUI

struct ClientsView: View {
    @Environment(\.openURL) private var openURL
    @State private var launchError: String?
    private let appStore = URL(string: "https://apps.apple.com/app/id6769185501")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clients").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            GroupBox("ArchiveBox App") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image("BrandLogo").resizable().scaledToFit().frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                        Button("iOS / iPadOS App Store", systemImage: "iphone.and.ipad") { openURL(appStore) }
                        Button("Open ArchiveBox.app", systemImage: "desktopcomputer") {
                            launchError = nil
                            if let app = AppInformation.installedClientURL {
                                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                                    Task { @MainActor in launchError = error?.localizedDescription }
                                }
                            } else {
                                openURL(appStore)
                            }
                        }
                    }.buttonStyle(.bordered)
                    Text("Connect to your ArchiveBox server from iPhone, iPad, or Mac. Save URLs from any app using the share sheet, choose a default persona, and browse your archive and admin pages. The Mac app also includes the Safari extension.")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if let launchError { Text(launchError).foregroundStyle(.red).textSelection(.enabled) }
            BrowserExtensionSetup(title: "ArchiveBox Browser Extension")
        }
    }
}
