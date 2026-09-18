import AppKit
import ArchiveBoxCore
import WebKit

// Exercise the client's actual cached webviews against the running companion.
// The existing administrator key never leaves this process or enters test output.
@main struct ClientBrowserAcceptance {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }

    @MainActor static func run() async throws {
        _ = NSApplication.shared
        let runtime = Runtime(resources: URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: "Contents/Resources"))
        let details = try runtime.management()
        guard details.hasAdmin, let token = try runtime.browserAPIKey() else {
            throw ArchiveBoxError.message("Create an administrator in the server app first.")
        }
        let api = try await ArchiveBoxClient().discoverServer(details.api.absoluteString)
        let login = try await ArchiveBoxClient().browserSession(server: api, token: token)
        print("API origin: \(api.host() ?? ""); browser origin: \(login.admin_url.host() ?? "")")
        let pages = WebPages()
        // The Settings sidebar signs in before the user opens their first webview.
        _ = try await pages.authentication.sidebarProgress(server: api, token: token)
        print("PASS: sidebar authenticated before the first embedded page existed")
        // Discovery first publishes a server without a verified token. Its old
        // asynchronous configure task could clear the sidebar's new session.
        pages.configure(server: api, baseURL: details.base, token: nil)
        for (key, path, selector) in [
            ("crawls", "admin/crawls/crawl/", "body.model-crawl.change-list"),
            ("snapshots", "admin/core/snapshot/", "body.model-snapshot.change-list"),
            ("add", "add/", "form"),
        ] {
            let destination = api.appending(path: path)
            // Credentials must reach the page even if SwiftUI has not run a
            // separate connection-change callback yet.
            let page = pages.page(for: key, baseURL: details.base, server: api, token: token)
            page.load(destination, requestID: nil)
            let deadline = Date().addingTimeInterval(15)
            var loaded = false
            while Date() < deadline {
                if let error = page.errorMessage { throw ArchiveBoxError.message(error) }
                if !page.page.isLoading, page.page.url?.path == destination.path,
                   let matches = try? await page.page.evaluateJavaScript("document.querySelector('\(selector)') !== null && document.querySelector('input[name=password]') === null") as? Bool,
                   matches {
                    loaded = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard loaded else {
                throw ArchiveBoxError.message("\(key) did not open authenticated; ended at \(page.page.url?.host() ?? "")\(page.page.url?.path ?? "")")
            }
            print("PASS: \(key) rendered authenticated in the client's real WKWebView")
        }
    }
}
