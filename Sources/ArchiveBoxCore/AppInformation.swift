import Foundation
#if os(macOS)
import AppKit
#endif

/// Shared destinations keep the client, companion, and their About panels consistent.
public enum AppInformation {
    public static let links: [(title: String, url: URL)] = [
        ("ArchiveBox Documentation", URL(string: "https://github.com/ArchiveBox/ArchiveBox/wiki")!),
        ("Getting Started", URL(string: "https://github.com/ArchiveBox/ArchiveBox/wiki/Quickstart")!),
        ("ArchiveBox Community Forum", URL(string: "https://zulip.archivebox.io")!),
        ("Report an App Issue", URL(string: "https://github.com/ArchiveBox/ios-archivebox/issues")!),
        ("Apple Apps Source Code", URL(string: "https://github.com/ArchiveBox/ios-archivebox")!),
        ("ArchiveBox Server Source Code", URL(string: "https://github.com/ArchiveBox/ArchiveBox")!),
        ("Browser Extension", URL(string: "https://github.com/ArchiveBox/archivebox-browser-extension")!),
    ]
    public static let clientDescription = "Save URLs from your apps and browsers to ArchiveBox, and browse your self-hosted collection. Requires an ArchiveBox 0.9 or newer server."
    public static let serverDescription = "Run a local ArchiveBox server on your Mac. Closing the window keeps the server running; Shut Down Server & Quit stops it safely."
    public static let copyright = "© 2026 ArchiveBox contributors"
    public static let licenseURL = URL(string: "https://github.com/ArchiveBox/ios-archivebox/blob/main/LICENSE")!

    #if os(macOS)
    @MainActor public static var installedClientURL: URL? {
        // Prefer an installed app; Launch Services also finds registered Xcode/TestFlight builds.
        let installed = [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/ArchiveBox.app"),
                         URL(fileURLWithPath: "/Applications/ArchiveBox.app")]
        return installed.first { Bundle(url: $0)?.bundleIdentifier == "io.archivebox.ArchiveBox" }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.archivebox.ArchiveBox")
    }

    @MainActor public static func showAbout(server: Bool = false) {
        let credits = NSMutableAttributedString(string: (server ? serverDescription : clientDescription) + "\n\n" + copyright + "\n\n")
        for link in links + [("Apple app license (GPLv3)", licenseURL)] {
            credits.append(NSAttributedString(string: link.title + "\n", attributes: [.link: link.url]))
        }
        if server {
            credits.append(NSAttributedString(string: "\nIncludes ArchiveBox, Apple container, SwiftTerm, and Sparkle, each under its own license.\n"))
        }
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: server ? "ArchiveBox Server" : "ArchiveBox",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
    #endif
}
