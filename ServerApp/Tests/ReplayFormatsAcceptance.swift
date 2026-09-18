import ArchiveBoxCore
import Foundation

// Read-only against a real capture made with the ordinary `archivebox add` CLI.
@main struct ReplayFormatsAcceptance {
    @MainActor static func main() async throws {
        let runtime = Runtime(resources: URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: "Contents/Resources"))
        let snapshot = CommandLine.arguments[2]
        let status = try await TailscaleNetwork.read()
        guard let ip = status.Self?.TailscaleIPs?.first(where: { !$0.contains(":") }), let token = try runtime.browserAPIKey() else {
            throw ArchiveBoxError.message("This acceptance check requires Tailscale and an administrator")
        }
        let hosts = ["archivebox.localhost", "admin.archivebox.localhost", "api.archivebox.localhost", "web.archivebox.localhost", ip] + NetworkAccess.lanAddresses()
        let client = ArchiveBoxClient()
        for host in hosts {
            let origin = URL(string: "http://\(host):18080")!
            let api = try await client.discoverServer(origin.absoluteString)
            try await client.testToken(server: api, token: token)
            let session = try await client.browserSession(server: api, token: token)
            let paths = ["admin/", "snapshot/\(snapshot)/", "snapshot/\(snapshot)/singlefile/singlefile.html", "snapshot/\(snapshot)/pdf/output.pdf", "snapshot/\(snapshot)/screenshot/screenshot.png"]
            for path in paths {
                var request = URLRequest(url: origin.appending(path: path))
                request.setValue("\(session.cookie.name)=\(session.cookie.value)", forHTTPHeaderField: "Cookie")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty, http.url?.path == request.url?.path else {
                    throw ArchiveBoxError.message("Failed to load \(request.url!)")
                }
                if path.hasSuffix("singlefile.html") {
                    guard String(decoding: data, as: UTF8.self).contains("Example Domain"), http.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("script-src 'none'") == true else {
                        throw ArchiveBoxError.message("SingleFile lost its content or archived-script protection")
                    }
                }
                if path.hasSuffix(".pdf") {
                    guard data.starts(with: Data("%PDF-".utf8)), http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/pdf") == true else {
                        throw ArchiveBoxError.message("PDF was not served as an intact PDF document")
                    }
                }
            }
            print("PASS: \(host): API authentication, admin, snapshot page, script-blocked SingleFile, PDF and screenshot")
        }
    }
}
