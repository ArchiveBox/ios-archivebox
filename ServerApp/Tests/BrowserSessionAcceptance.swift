import ArchiveBoxCore
import Foundation

// Exercises the real bundled server and its existing administrator key. Never
// print credentials or session cookies, and do not create replacement users.
@main struct BrowserSessionAcceptance {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw ArchiveBoxError.message("Pass ArchiveBox Server.app's path") }
        let runtime = Runtime(resources: URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: "Contents/Resources"))
        let details = try runtime.management()
        guard details.hasAdmin, let token = try runtime.browserAPIKey() else {
            throw ArchiveBoxError.message("Create the first administrator in the server app before running this acceptance check.")
        }
        let client = ArchiveBoxClient()
        let api = try await client.discoverServer(details.api.absoluteString)
        try await client.testToken(server: api, token: token)
        let login = try await client.browserSession(server: api, token: token)
        guard login.cookie.expires > Date().timeIntervalSince1970, !login.cookie.value.isEmpty else {
            throw ArchiveBoxError.message("Server returned an expired or empty browser session.")
        }
        var request = URLRequest(url: login.admin_url)
        request.setValue("\(login.cookie.name)=\(login.cookie.value)", forHTTPHeaderField: "Cookie")
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.path == login.admin_url.path else {
            throw ArchiveBoxError.message("Browser session did not open the administrator page.")
        }
        if details.configuredBaseURL == "", details.securityMode == "safe-onedomain-nojsreplay" {
            let html = String(decoding: body, as: UTF8.self)
            guard !html.contains("archivebox-setup-wizard"), !html.lowercased().contains("base_url not set") else {
                throw ArchiveBoxError.message("Automatic network setup must not display a second setup wizard or require BASE_URL.")
            }
        }
        print("PASS: API discovered; administrator key accepted; browser session issued; authenticated admin page returned HTTP 200 without a login redirect")
    }
}
