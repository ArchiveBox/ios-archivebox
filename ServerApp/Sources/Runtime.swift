import AppKit
import WebKit

struct CommandFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Reuse Apple's released runtime; this app only owns its lifecycle and UI.
final class Runtime: @unchecked Sendable {
    let resources: URL
    init(resources: URL = Bundle.main.resourceURL!) { self.resources = resources }
    let home = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ArchiveBox Server")
    var root: URL { home.appendingPathComponent("runtime") }
    var cli: URL { resources.appendingPathComponent("runtime/bin/container") }
    let name = "archivebox-server"
    let address = URL(string: "http://archivebox.localhost:18080")!
    var ownsService = false

    func command(_ args: [String], allowFailure: Bool = false, logOutput: Bool = true,
                 input: Data? = nil, executable: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = executable ?? cli
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
        try process.run()
        if let input {
            // Credentials travel through stdin, never command arguments, environment,
            // or desktop.log. Management requests are small JSON documents.
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        }
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: bytes, as: UTF8.self)
        let log = home.appendingPathComponent("desktop.log")
        if logOutput, let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data(("\n> container " + args.joined(separator: " ") + "\n" + output).utf8))
            try? handle.close()
        }
        if process.terminationStatus != 0 && !allowFailure {
            throw CommandFailure(message: "container \(args.joined(separator: " "))\n\(output)")
        }
        return output
    }

    func start(progress: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent("data"), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: home.appendingPathComponent("desktop.log").path) {
            fm.createFile(atPath: home.appendingPathComponent("desktop.log").path, contents: nil)
        }
        let status = try command(["system", "status", "--format", "json"], allowFailure: true)
        if let json = status.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
           object["status"] as? String == "running" {
            let paths = object["paths"] as? [String: String]
            guard let path = paths?["appRoot"], URL(fileURLWithPath: path).standardizedFileURL == root.standardizedFileURL else {
                throw CommandFailure(message: "Apple Container is already running with another data directory. Quit its workloads and stop that service before opening ArchiveBox Server. ArchiveBox has not changed it.")
            }
            ownsService = true
        } else {
            guard status.contains("\"unregistered\"") else {
                throw CommandFailure(message: "An Apple Container service is registered but unavailable. Resolve that service before starting ArchiveBox.\n\(status)")
            }
            progress("Starting the bundled Linux runtime…")
            _ = try command(["system", "start", "--app-root", root.path,
                             "--install-root", resources.appendingPathComponent("runtime").path,
                             "--disable-kernel-install"])
            ownsService = true
        }
        _ = try command(["system", "kernel", "set", "--force", "--binary", resources.appendingPathComponent("vmlinux").path])
        // Validate actual runtime state rather than trusting an install marker
        // after an interrupted import or a user clearing the image store.
        let imagesPresent = (try? command(["image", "inspect", "archivebox/archivebox:dev", "ghcr.io/apple/containerization/vminit:0.45.0"], logOutput: false)) != nil
        if !imagesPresent {
            progress("Preparing ArchiveBox for its first launch…")
            _ = try command(["image", "load", "--input", resources.appendingPathComponent("images.tar").path])
        }
        progress("Starting ArchiveBox…")
        let existing = try command(["list", "--all", "--format", "json"])
        let containers = (try JSONSerialization.jsonObject(with: Data(existing.utf8))) as? [[String: Any]] ?? []
        let container = containers.first { ($0["configuration"] as? [String: Any])?["id"] as? String == name }
        if let container {
            if (container["status"] as? [String: Any])?["state"] as? String != "running" { _ = try command(["start", name]) }
        } else {
            if !fm.fileExists(atPath: home.appendingPathComponent("data/index.sqlite3").path) {
                _ = try command(["run", "--rm", "--volume", home.appendingPathComponent("data").path + ":/data",
                                 "archivebox/archivebox:dev", "/bin/sh", "-c",
                                 "archivebox init && archivebox config --set BASE_URL=http://archivebox.localhost:18080"])
            }
            try runContainer()
        }
        try await waitUntilReady()
    }

    private func runContainer() throws {
        // Configuration belongs to ArchiveBox.conf / Machine.config. Environment
        // overrides would silently mask subsequent edits made in either Settings UI.
        _ = try command(["run", "--detach", "--name", name, "--cpus", "4", "--memory", "4G",
                         "--publish", "127.0.0.1:18080:8000",
                         "--volume", home.appendingPathComponent("data").path + ":/data", "archivebox/archivebox:dev"])
    }

    func applyHTTPSettings(baseURL: String, securityMode: String) async throws -> ServerDetails {
        guard var url = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", url.port == nil || (1...65535).contains(url.port!) else {
            throw CommandFailure(message: "Enter an http:// or https:// server origin, including its port when needed, without a path or credentials.")
        }
        url.path = ""
        guard let normalized = url.url?.absoluteString else { throw CommandFailure(message: "Invalid BASE_URL.") }
        let current = try management()
        guard current.securityModes.contains(securityMode) else { throw CommandFailure(message: "Choose a security mode supported by this server.") }
        // Use the real config CLI, with legacy container environment overrides
        // removed for this command, so validation and file/DB synchronization run.
        _ = try command(["exec", "--workdir", "/data", name, "/usr/bin/env", "-u", "BASE_URL", "-u", "SERVER_SECURITY_MODE",
                         "/app/bin/docker_entrypoint.sh", "archivebox", "config", "--set",
                         "BASE_URL=\(normalized)", "SERVER_SECURITY_MODE=\(securityMode)"])
        _ = try command(["stop", name])
        // Older app builds set an immutable BASE_URL environment variable. Replace
        // only the container, preserving the mounted collection and all its users.
        _ = try command(["delete", name])
        try runContainer()
        try await waitUntilReady()
        let updated = try management()
        guard updated.base.absoluteString == normalized, updated.securityMode == securityMode else {
            throw CommandFailure(message: "The server restarted but its effective settings do not match the requested values. Check ArchiveBox.conf and the server logs.")
        }
        return updated
    }

    private func waitUntilReady() async throws {
        // Startup readiness, not a retry of failed operations. Surface the logs on timeout.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            // Readiness must not depend on the user's DNS, TLS proxy or host routing.
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18080/health/")!)
            request.timeoutInterval = 2
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) { return }
            } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
                throw error // A transport policy failure cannot heal while waiting for boot.
            } catch { /* The server may still be initializing its collection. */ }
            try await Task.sleep(for: .seconds(1))
        }
        throw CommandFailure(message: "ArchiveBox did not become ready.\n" + (try command(["logs", name], allowFailure: true)))
    }

    func stop() {
        guard ownsService,
              let output = try? command(["system", "status", "--format", "json"], logOutput: false),
              let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let path = (object["paths"] as? [String: String])?["appRoot"],
              URL(fileURLWithPath: path).standardizedFileURL == root.standardizedFileURL else { return }
        _ = try? command(["stop", name], allowFailure: true)
        // Stop only this app’s workload. Other containers may have been added
        // through the terminal; do not terminate them when this app quits.
    }
}
