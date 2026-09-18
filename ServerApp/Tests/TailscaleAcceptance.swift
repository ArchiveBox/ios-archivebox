import ArchiveBoxCore
import Foundation

// Real Tailscale Serve and the installed companion. Restores the previous HTTP
// configuration unless --keep is explicitly supplied for local setup acceptance.
@main struct TailscaleAcceptance {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count >= 2 else { throw ArchiveBoxError.message("Pass the installed companion path") }
        let runtime = Runtime(resources: URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: "Contents/Resources"))
        let original = try runtime.management()
        let network = try await TailscaleNetwork.read()
        let proxy = NetworkAccess(runtime: runtime)
        let served: URL
        if CommandLine.arguments.contains("--direct") {
            guard let ip = network.Self?.TailscaleIPs?.first(where: { !$0.contains(":") }) else { throw ArchiveBoxError.message("No tailnet IPv4") }
            var options = NetworkOptions(); options.lan = true; options.tailnet = true
            _ = try await proxy.start(options: options)
            served = URL(string: "http://\(ip):5797")!
        } else {
            guard let address = try runtime.tailscaleAddress(port: 5797) else { throw ArchiveBoxError.message("No Serve listener") }
            served = address
        }

        guard let token = try runtime.browserAPIKey() else { throw ArchiveBoxError.message("No admin key") }
        let keep = CommandLine.arguments.contains("--keep")
        do {
            let changed = try await runtime.applyHTTPSettings(baseURL: served.absoluteString, securityMode: "safe-onedomain-nojsreplay")
            guard changed.users.map(\.id) == original.users.map(\.id) else { throw ArchiveBoxError.message("Users changed") }
            let client = ArchiveBoxClient()
            let api = try await client.discoverServer(served.absoluteString)
            try await client.testToken(server: api, token: token)
            let login = try await client.browserSession(server: api, token: token)
            guard login.admin_url.host() == served.host(), login.admin_url.scheme == served.scheme else { throw ArchiveBoxError.message("Admin left the tailnet origin") }
            var request = URLRequest(url: login.admin_url)
            request.setValue("\(login.cookie.name)=\(login.cookie.value)", forHTTPHeaderField: "Cookie")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.path == login.admin_url.path else {
                throw ArchiveBoxError.message("Authenticated admin did not load")
            }
            print("PASS: real tailnet connection (\(served.scheme!)); ArchiveBox API; existing API key; browser session; authenticated admin; users preserved")
            if !keep { _ = try await runtime.applyHTTPSettings(baseURL: original.configuredBaseURL ?? original.base.absoluteString, securityMode: original.securityMode) }
            await proxy.stop()
        } catch {
            await proxy.stop()
            _ = try await runtime.applyHTTPSettings(baseURL: original.configuredBaseURL ?? original.base.absoluteString, securityMode: original.securityMode)
            throw error
        }
    }
}
