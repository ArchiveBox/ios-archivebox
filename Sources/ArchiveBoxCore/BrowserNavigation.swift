import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One boundary for the SwiftUI client and the companion's WKWebViews.
@MainActor public final class BrowserNavigation: WebPage.NavigationDeciding {
    public var baseURL: URL?
    public weak var page: WebPage?

    public init(baseURL: URL? = nil) { self.baseURL = baseURL }

    public nonisolated static func belongsToServer(_ url: URL, baseURL: URL?) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              let base = baseURL?.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !base.isEmpty else { return false }
        if host == base { return true }
        // IP addresses have no subdomains; the dot boundary also rejects lookalikes
        // such as notarchive.example and archive.example.attacker.test.
        let isIP = base.contains(":") || base.split(separator: ".").allSatisfy { UInt8($0) != nil }
        return !isIP && host.hasSuffix("." + base)
    }

    @discardableResult
    public func openExternallyIfNeeded(_ url: URL, isLink: Bool, targetIsMainFrame: Bool?) -> Bool {
        // Resource frames must continue loading in place. User-clicked links inside
        // those frames are navigations too, including archived pages and PDF links.
        guard isLink || targetIsMainFrame != false else { return false }
        guard !["about", "blob", "data", "javascript"].contains(url.scheme?.lowercased() ?? ""),
              !Self.belongsToServer(url, baseURL: baseURL) else { return false }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
        return true
    }

    public func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if openExternallyIfNeeded(url, isLink: action.navigationType == .linkActivated,
                                  targetIsMainFrame: action.target?.isMainFrame) { return .cancel }
        // WebView has no tab/window UI: keep internal target=_blank links in the
        // existing authenticated page instead of silently dropping the click.
        if action.target == nil {
            page?.load(action.request)
            return .cancel
        }
        return .allow
    }
}
