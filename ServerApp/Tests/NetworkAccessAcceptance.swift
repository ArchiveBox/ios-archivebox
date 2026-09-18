import ArchiveBoxCore
import Foundation

@main struct NetworkAccessAcceptance {
    @MainActor static func main() async throws {
        let runtime = Runtime(resources: URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: "Contents/Resources"))
        let original = try runtime.management()
        guard let token = try runtime.browserAPIKey() else { throw ArchiveBoxError.message("Create an administrator first") }
        let access = NetworkAccess(runtime: runtime)
        let options = NetworkOptions()
        do {
            let urls = try await access.start(options: options)
            guard urls.contains(where: { $0.host()?.hasPrefix("100.") == true }), urls.count >= 2 else { throw ArchiveBoxError.message("This check requires a real LAN and Tailscale connection") }
            let automatic = try await runtime.applyHTTPSettings(baseURL: "", securityMode: "safe-onedomain-nojsreplay")
            guard automatic.configuredBaseURL == "", automatic.api.host() == "archivebox.localhost", automatic.api.port == 5797 else {
                throw ArchiveBoxError.message("Automatic settings returned an unreachable native sign-in address: \(automatic.api)")
            }
            let client = ArchiveBoxClient()
            let native = try await client.discoverServer(automatic.api.absoluteString)
            try await client.testToken(server: native, token: token)
            for url in urls + [ServerAddress.localServer] {
                let api = try await client.discoverServer(url.absoluteString)
                try await client.testToken(server: api, token: token)
                let session = try await client.browserSession(server: api, token: token)
                guard session.admin_url.host() == url.host(), session.admin_url.port == url.port else { throw ArchiveBoxError.message("Browser session switched network origin: \(url) -> \(session.admin_url)") }
                var request = URLRequest(url: session.admin_url)
                request.setValue("\(session.cookie.name)=\(session.cookie.value)", forHTTPHeaderField: "Cookie")
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.path == session.admin_url.path else { throw ArchiveBoxError.message("Sign-in did not survive on \(url)") }
            }
            print("PASS: real localhost, LAN and tailnet API discovery; existing API key; authenticated admin on each original host")
            var restricted = options; restricted.lan = false
            let tailnetOnly = try await access.start(options: restricted)
            guard tailnetOnly.count == 1, tailnetOnly[0].host()?.hasPrefix("100.") == true else { throw ArchiveBoxError.message("LAN toggle did not narrow listeners") }
            for removed in urls.filter({ !tailnetOnly.contains($0) }) { try await requireClosed(removed) }
            restricted = options; restricted.tailnet = false
            let lanOnly = try await access.start(options: restricted)
            guard !lanOnly.isEmpty, !lanOnly.contains(where: { $0.host()?.hasPrefix("100.") == true }) else { throw ArchiveBoxError.message("Tailnet toggle did not narrow listeners") }
            try await requireClosed(tailnetOnly[0])
            _ = try await client.discoverServer(ServerAddress.localServer.absoluteString)
            print("PASS: each network toggle closes its real listener independently; localhost remains available")
            await access.stop()
            if CommandLine.arguments.contains("--keep") { options.save() }
            else { _ = try await runtime.applyHTTPSettings(baseURL: original.configuredBaseURL ?? original.base.absoluteString, securityMode: original.securityMode) }
        } catch {
            await access.stop()
            _ = try await runtime.applyHTTPSettings(baseURL: original.configuredBaseURL ?? original.base.absoluteString, securityMode: original.securityMode)
            throw error
        }
    }
    private static func requireClosed(_ url: URL) async throws {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: url.appending(path: "health/"))
        } catch { return }
        throw ArchiveBoxError.message("Disabled listener still accepts connections: \(url)")
    }
}
