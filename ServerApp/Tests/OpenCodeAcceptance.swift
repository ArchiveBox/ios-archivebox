import ArchiveBoxCore
import Foundation

// Exercise the installed image through the companion's normal administrator
// session exchange. Never print the API key or browser session cookie.
@main struct OpenCodeAcceptance {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw ArchiveBoxError.message("Pass ArchiveBox Server.app's path") }
        let runtime = Runtime(resources: URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: "Contents/Resources"))
        let details = try runtime.management()
        guard details.hasAdmin, let token = try runtime.browserAPIKey() else {
            throw ArchiveBoxError.message("Create the first administrator in the server app before running this acceptance check.")
        }
        let client = ArchiveBoxClient()
        let api = try await client.discoverServer(details.api.absoluteString)
        let login = try await client.browserSession(server: api, token: token)
        func get(_ path: String) async throws -> Data {
            let url = URL(string: path, relativeTo: login.admin_url)!.absoluteURL
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            request.setValue("\(login.cookie.name)=\(login.cookie.value)", forHTTPHeaderField: "Cookie")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.path == url.path else {
                throw ArchiveBoxError.message("OpenCode request failed: \(path)")
            }
            return data
        }
        let page = String(decoding: try await get("/admin/agent/"), as: UTF8.self)
        guard page.contains("title=\"OpenCode Agent\""), !page.contains("opencode-agent-error\">") else {
            throw ArchiveBoxError.message("Agent page did not render its OpenCode iframe.")
        }
        let health = try JSONSerialization.jsonObject(with: await get("/admin/agent/opencode/global/health")) as? [String: Any]
        guard health?["healthy"] as? Bool == true, let version = health?["version"] as? String else {
            throw ArchiveBoxError.message("OpenCode did not report a healthy server and version.")
        }
        let providers = try JSONSerialization.jsonObject(with: await get("/admin/agent/opencode/provider")) as? [String: Any]
        guard let all = providers?["all"] as? [[String: Any]], !all.isEmpty else {
            throw ArchiveBoxError.message("OpenCode's provider catalog is empty.")
        }
        print("PASS: authenticated agent iframe, OpenCode \(version) healthy, \(all.count) providers available")
    }
}
