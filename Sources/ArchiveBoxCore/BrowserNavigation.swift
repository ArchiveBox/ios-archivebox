import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One boundary for the SwiftUI client and the companion's WKWebViews.
@MainActor public final class BrowserNavigation: NSObject, WKNavigationDelegate, WKUIDelegate {
    public var baseURL: URL?
    /// Exact admin origin returned by the authenticated session endpoint.
    public var authenticatedOrigin: URL?
    public var openSnapshot: ((URL) -> Void)?
    public var didStartProvisional: ((WKWebView) -> Void)?
    public var didCommit: ((WKWebView) -> Void)?
    public var didFinish: ((WKWebView) -> Void)?
    public var didFail: ((Error) -> Void)?

    public init(baseURL: URL? = nil) { self.baseURL = baseURL; super.init() }

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
        if let origin = authenticatedOrigin, url.scheme == origin.scheme,
           url.host == origin.host, url.port == origin.port { return false }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
        return true
    }

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let isMainFrame = action.targetFrame?.isMainFrame != false
        guard let url = action.request.url else {
            if isMainFrame { NSLog("ArchiveBox navigation policy: cancel missing URL") }
            decisionHandler(.cancel)
            return
        }
        let matchesBase = Self.belongsToServer(url, baseURL: baseURL)
        let matchesAdminOrigin = authenticatedOrigin.map {
            url.scheme == $0.scheme && url.host == $0.host && url.port == $0.port
        } ?? false
        if openExternallyIfNeeded(url, isLink: action.navigationType == .linkActivated,
                                  targetIsMainFrame: action.targetFrame?.isMainFrame) {
            if isMainFrame {
                NSLog("ArchiveBox navigation policy: external cancel baseMatch=%d adminOriginMatch=%d",
                      matchesBase ? 1 : 0, matchesAdminOrigin ? 1 : 0)
            }
            decisionHandler(.cancel); return
        }
        if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame != false,
           !action.shouldPerformDownload, let openSnapshot,
           Self.isSnapshotDetail(url) {
            openSnapshot(url)
            NSLog("ArchiveBox navigation policy: snapshot cancel baseMatch=%d adminOriginMatch=%d",
                  matchesBase ? 1 : 0, matchesAdminOrigin ? 1 : 0)
            decisionHandler(.cancel); return
        }
        if isMainFrame {
            NSLog("ArchiveBox navigation policy: %@ baseMatch=%d adminOriginMatch=%d",
                  action.shouldPerformDownload ? "download" : "allow",
                  matchesBase ? 1 : 0, matchesAdminOrigin ? 1 : 0)
        }
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }

    public nonisolated static func isSnapshotDetail(_ url: URL) -> Bool {
        func isSnapshotID(_ value: Substring) -> Bool {
            UUID(uuidString: String(value)) != nil ||
                (value.count == 32 && value.allSatisfy { $0.isASCII && $0.isHexDigit })
        }
        let parts = url.path.split(separator: "/")
        if parts.count == 5, parts.prefix(3) == ["admin", "core", "snapshot"],
           parts.last == "change", isSnapshotID(parts[3]) { return true }
        if parts.isEmpty, let host = url.host?.split(separator: ".").first,
           host.hasPrefix("snap-"), host.dropFirst(5).allSatisfy({ $0.isASCII && $0.isHexDigit }),
           host.count > 5 { return true }
        if parts.count == 4, parts[1].count == 8, parts[1].allSatisfy(\.isNumber),
           isSnapshotID(parts[3]) { return true }
        if parts.count == 2, parts.first == "archive", Double(parts[1]) != nil { return true }
        // Snapshot previews link to the normal archived detail page. Keep the
        // server's URL intact, including username/date/domain archive paths.
        return parts.last == "index.html" &&
            (parts.first == "archive" || parts.contains(where: isSnapshotID))
    }

    public func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        decisionHandler(!response.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") ? .download : .allow)
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        BrowserDownloads.shared.track(download)
    }
    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        BrowserDownloads.shared.track(download)
    }
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Reuse the authenticated view for internal new-window links. External
        // links have already been cancelled by the navigation policy above.
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { didCommit?(webView) }
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        didStartProvisional?(webView)
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { didFinish?(webView) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
    private func report(_ error: Error) {
        // A cancelled navigation is expected when handing a link to the browser
        // or converting it into a download; it must not cover the page in an error.
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return }
        didFail?(error)
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        dialog(webView, message: message, cancel: false) { _ in completionHandler() }
    }
    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        dialog(webView, message: message, cancel: true) { completionHandler($0 != nil) }
    }
    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        dialog(webView, message: prompt, cancel: true, input: defaultText ?? "", completion: completionHandler)
    }
    private func dialog(_ webView: WKWebView, message: String, cancel: Bool, input: String? = nil,
                        completion: @escaping @MainActor (String?) -> Void) {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = webView.url?.host ?? "ArchiveBox"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if cancel { alert.addButton(withTitle: "Cancel") }
        let field = input.map { NSTextField(string: $0) }
        if let field { field.frame.size = NSSize(width: 300, height: 24); alert.accessoryView = field }
        let finish: (NSApplication.ModalResponse) -> Void = { completion($0 == .alertFirstButtonReturn ? field?.stringValue ?? "" : nil) }
        if let window = webView.window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
        #else
        var presenter = webView.window?.rootViewController
        while let presented = presenter?.presentedViewController { presenter = presented }
        guard let presenter else { completion(nil); return }
        let alert = UIAlertController(title: webView.url?.host ?? "ArchiveBox", message: message, preferredStyle: .alert)
        if let input { alert.addTextField { $0.text = input } }
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion(alert.textFields?.first?.text ?? "") })
        if cancel { alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) }) }
        presenter.present(alert, animated: true)
        #endif
    }

    #if os(macOS)
    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { response in completionHandler(response == .OK ? panel.urls : nil) }
    }
    #endif
}
