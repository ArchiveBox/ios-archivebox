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
            _ = try command(["run", "--detach", "--name", name, "--cpus", "4", "--memory", "4G",
                             "--publish", "127.0.0.1:18080:8000",
                             "--volume", home.appendingPathComponent("data").path + ":/data",
                             "--env", "BASE_URL=http://archivebox.localhost:18080", "archivebox/archivebox:dev"])
        }
        // Startup readiness, not a retry of failed operations. Surface the logs on timeout.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            var request = URLRequest(url: address)
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
