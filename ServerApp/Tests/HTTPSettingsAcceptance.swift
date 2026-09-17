import ArchiveBoxCore
import Foundation

// Runs against the actual companion, restarts its container, then restores the
// original effective settings. The mounted collection is never removed.
@main struct HTTPSettingsAcceptance {
    static func check(_ condition: Bool, line: Int = #line) throws {
        if !condition { throw ArchiveBoxError.message("HTTP settings assertion failed at line \(line)") }
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw ArchiveBoxError.message("Pass ArchiveBox Server.app's path") }
        let runtime = Runtime(resources: URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: "Contents/Resources"))
        let original = try runtime.management()
        func configuration() throws -> [String: Any] {
            let json = try runtime.command(["list", "--all", "--format", "json"], logOutput: false)
            let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
            return rows.first { $0["id"] as? String == runtime.name }!["configuration"] as! [String: Any]
        }
        let before = try configuration()
        do {
            _ = try await runtime.applyHTTPSettings(baseURL: "https://user:secret@example.com/path", securityMode: "auto")
            throw NSError(domain: "Invalid URL accepted", code: 1)
        } catch let error as ArchiveBoxError { try check(error.localizedDescription.contains("server origin")) }
        let afterInvalid = try configuration()
        try check(before["creationDate"] as? String == afterInvalid["creationDate"] as? String)
        do {
            let changed = try await runtime.applyHTTPSettings(baseURL: "http://http-settings.archivebox.localhost:18080", securityMode: "safe-onedomain-nojsreplay")
            try check(changed.base.absoluteString == "http://http-settings.archivebox.localhost:18080")
            try check(changed.admin.host == changed.base.host && changed.api.host == changed.base.host)
            let running = try configuration()
            // A restart picks up ArchiveBox.conf without replacing the container.
            try check(running["creationDate"] as? String == before["creationDate"] as? String)
            let environment = (running["initProcess"] as! [String: Any])["environment"] as! [String]
            try check(!environment.contains { $0.hasPrefix("BASE_URL=") || $0.hasPrefix("SERVER_SECURITY_MODE=") })
            let (_, response) = try await URLSession.shared.data(from: changed.base)
            try check((response as? HTTPURLResponse)?.statusCode == 200)
            let restored = try await runtime.applyHTTPSettings(baseURL: original.base.absoluteString, securityMode: original.securityMode)
            try check(restored.base == original.base && restored.securityMode == original.securityMode)
            try check(restored.users.map(\.id) == original.users.map(\.id))
            print("PASS: invalid input leaves container unchanged; config saved; container restarted without replacement; new host responds; original settings restored; users preserved")
        } catch {
            _ = try await runtime.applyHTTPSettings(baseURL: original.base.absoluteString, securityMode: original.securityMode)
            throw error
        }
    }
}
