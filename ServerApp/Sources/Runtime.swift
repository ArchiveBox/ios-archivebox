import AppKit
import ArchiveBoxCore
import Synchronization

// Reuse Apple's released runtime; this app only owns its lifecycle and UI.
final class Runtime: Sendable {
    let resources: URL
    init(resources: URL = Bundle.main.resourceURL!) { self.resources = resources }
    let home = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ArchiveBox Server")
    var collectionDirectory: URL {
        if let path = try? String(contentsOf: home.appendingPathComponent("collection-path.txt"), encoding: .utf8), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return home.appendingPathComponent("data", isDirectory: true)
    }
    var root: URL { home.appendingPathComponent("runtime") }
    var cli: URL { resources.appendingPathComponent("runtime/bin/container") }
    let name = "archivebox-server"
    let address = ServerAddress.localServer
    // Startup and background sampling share this single mutable ownership flag.
    private let serviceOwnership = Mutex(false)
    var ownsService: Bool {
        get { serviceOwnership.withLock { $0 } }
        set { serviceOwnership.withLock { $0 = newValue } }
    }

    func command(_ args: [String], allowFailure: Bool = false, logOutput: Bool = true,
                 input: Data? = nil, executable: URL? = nil) throws -> String {
        let executable = executable ?? cli
        let result = try ProcessCommand.run(executable, args, input: input)
        let output = result.output
        let log = home.appendingPathComponent("desktop.log")
        if logOutput, let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data(("\n> \(executable.lastPathComponent) " + args.joined(separator: " ") + "\n" + output).utf8))
            try? handle.close()
        }
        if result.status != 0 && !allowFailure {
            throw ArchiveBoxError.message("\(executable.lastPathComponent) \(args.joined(separator: " "))\n\(output)")
        }
        return output
    }

    func start(progress: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        if fm.fileExists(atPath: home.appendingPathComponent("collection-path.txt").path) {
            guard fm.isWritableFile(atPath: collectionDirectory.path) else { throw ArchiveBoxError.message("The selected collection folder is unavailable or not writable: \(collectionDirectory.path)") }
        } else { try fm.createDirectory(at: collectionDirectory, withIntermediateDirectories: true) }
        if !fm.fileExists(atPath: home.appendingPathComponent("desktop.log").path) {
            fm.createFile(atPath: home.appendingPathComponent("desktop.log").path, contents: nil)
        }
        let status = try command(["system", "status", "--format", "json"], allowFailure: true)
        if let json = status.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
           object["status"] as? String == "running" {
            let paths = object["paths"] as? [String: String]
            guard let path = paths?["appRoot"], URL(fileURLWithPath: path).standardizedFileURL == root.standardizedFileURL else {
                throw ArchiveBoxError.message("Apple Container is already running with another data directory. Quit its workloads and stop that service before opening ArchiveBox Server. ArchiveBox has not changed it.")
            }
            ownsService = true
        } else {
            guard status.contains("\"unregistered\"") else {
                throw ArchiveBoxError.message("An Apple Container service is registered but unavailable. Resolve that service before starting ArchiveBox.\n\(status)")
            }
            progress("Starting the bundled Linux runtime…")
            _ = try command(["system", "start", "--app-root", root.path,
                             "--install-root", resources.appendingPathComponent("runtime").path,
                             "--disable-kernel-install"])
            ownsService = true
        }
        // After a bundle update, activate its runtime helpers too. Do not stop
        // another workload somebody started through the embedded terminal.
        if let object = try? JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any],
           let client = object["client"] as? [String: Any], let server = object["server"] as? [String: Any],
           client["version"] as? String != server["version"] as? String {
            let rows = try JSONSerialization.jsonObject(with: Data(command(["list", "--all", "--format", "json"], logOutput: false).utf8)) as? [[String: Any]] ?? []
            guard !rows.contains(where: { $0["id"] as? String != name && ($0["status"] as? [String: Any])?["state"] as? String == "running" }) else {
                throw ArchiveBoxError.message("Stop other containers before activating the updated bundled runtime.")
            }
            _ = try command(["stop", name], allowFailure: true)
            _ = try command(["system", "stop"])
            _ = try command(["system", "start", "--app-root", root.path, "--install-root", resources.appendingPathComponent("runtime").path, "--disable-kernel-install"])
        }
        let info = Bundle(url: resources.deletingLastPathComponent().deletingLastPathComponent())?.infoDictionary ?? [:]
        let bundleBuild = info["CFBundleVersion"] as? String
        let marker = home.appendingPathComponent("installed-bundle-build.txt")
        let bundleChanged = bundleBuild != nil && (try? String(contentsOf: marker, encoding: .utf8)) != bundleBuild
        _ = try command(["system", "kernel", "set", "--force", "--binary", resources.appendingPathComponent("vmlinux").path])
        // Validate actual runtime state rather than trusting an install marker
        // after an interrupted import or a user clearing the image store.
        let imagesPresent = (try? command(["image", "inspect", "archivebox/archivebox:dev", "ghcr.io/apple/containerization/vminit:0.45.0"], logOutput: false)) != nil
        if !imagesPresent || bundleChanged {
            progress("Preparing ArchiveBox for its first launch…")
            _ = try command(["image", "load", "--input", resources.appendingPathComponent("images.tar").path])
        }
        progress("Starting ArchiveBox…")
        let existing = try command(["list", "--all", "--format", "json"])
        let containers = (try JSONSerialization.jsonObject(with: Data(existing.utf8))) as? [[String: Any]] ?? []
        let container = containers.first { ($0["configuration"] as? [String: Any])?["id"] as? String == name }
        // Container environments are immutable. Bundle updates recreate only
        // this app's container while preserving its mounted collection.
        if let container, !bundleChanged {
            if (container["status"] as? [String: Any])?["state"] as? String != "running" { _ = try command(["start", name]) }
        } else {
            if container != nil {
                _ = try command(["stop", name], allowFailure: true)
                _ = try command(["delete", name])
            }
            if !fm.fileExists(atPath: collectionDirectory.appendingPathComponent("index.sqlite3").path) {
                _ = try command(["run", "--rm", "--env", "OPENCODE_ENABLED=true", "--volume", collectionDirectory.path + ":/data",
                                 "archivebox/archivebox:dev", "/bin/sh", "-c",
                                 "archivebox init && archivebox config --set BASE_URL=\(address.absoluteString)"])
            }
            try runContainer()
        }
        try await waitUntilReady()
        if let bundleBuild { try bundleBuild.write(to: marker, atomically: true, encoding: .utf8) }
    }

    func prepareCollection(_ directory: URL) throws {
        let directory = directory.standardizedFileURL
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey])
        guard ownsService, values.isDirectory == true, values.isWritable == true, !directory.path.contains(":") else {
            throw ArchiveBoxError.message("Choose a writable folder whose path does not contain a colon.")
        }
        let rows = try JSONSerialization.jsonObject(with: Data(command(["list", "--all", "--format", "json"], logOutput: false).utf8)) as? [[String: Any]] ?? []
        for ownedName in [name, name + "-init"] {
            if let container = rows.first(where: { $0["id"] as? String == ownedName }) {
                if (container["status"] as? [String: Any])?["state"] as? String == "running" { _ = try command(["stop", ownedName]) }
                _ = try command(["delete", ownedName])
            }
        }
        try directory.path.write(to: home.appendingPathComponent("collection-path.txt"), atomically: true, encoding: .utf8)
    }

    var initializeCollectionArguments: [String] {
        let newCollection = !FileManager.default.fileExists(atPath: collectionDirectory.appendingPathComponent("index.sqlite3").path)
        return ["run", "--rm", "--interactive", "--tty", "--name", name + "-init", "--env", "TERM=xterm-256color", "--env", "OPENCODE_ENABLED=true",
                "--workdir", "/data", "--volume", collectionDirectory.path + ":/data", "archivebox/archivebox:dev",
                "/bin/bash", "--noprofile", "--norc", "-c",
                "printf '$ archivebox init\\n'; archivebox init" + (newCollection ? " && archivebox config --set BASE_URL=\(address.absoluteString)" : "")]
    }

    func startCollection() async throws { try runContainer(); try await waitUntilReady() }

    private func runContainer() throws {
        // The bundled product always includes the agent. Keep HTTP/DNS settings
        // in ArchiveBox.conf, but deliberately override the optional-plugin default.
        _ = try command(["run", "--detach", "--name", name, "--cpus", "4", "--memory", "4G",
                         "--env", "OPENCODE_ENABLED=true", "--publish", "127.0.0.1:\(address.port!):8000",
                         "--volume", collectionDirectory.path + ":/data", "archivebox/archivebox:dev"])
        // Dependency installs in a previous container's writable layer do not
        // survive recreation. Resolve them again without modifying the image.
        _ = try command(["exec", "--workdir", "/data", name, "/app/bin/docker_entrypoint.sh",
                         "archivebox", "install", "opencode"])
    }

    func applyHTTPSettings(baseURL: String, securityMode: String) async throws -> ServerDetails {
        guard var url = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", url.port == nil || (1...65535).contains(url.port!) else {
            throw ArchiveBoxError.message("Enter an http:// or https:// server origin, including its port when needed, without a path or credentials.")
        }
        url.path = ""
        guard let normalized = url.url?.absoluteString else { throw ArchiveBoxError.message("Invalid BASE_URL.") }
        let current = try management()
        guard current.securityModes.contains(securityMode) else { throw ArchiveBoxError.message("Choose a security mode supported by this server.") }
        // Use the real config CLI so validation and file/DB synchronization run.
        _ = try command(["exec", "--workdir", "/data", name,
                         "/app/bin/docker_entrypoint.sh", "archivebox", "config", "--set",
                         "BASE_URL=\(normalized)", "SERVER_SECURITY_MODE=\(securityMode)"])
        let updated = try await restartContainer()
        guard updated.base.absoluteString == normalized, updated.securityMode == securityMode else {
            throw ArchiveBoxError.message("The server restarted but its effective settings do not match the requested values. Check ArchiveBox.conf and the server logs.")
        }
        return updated
    }

    func restartContainer() async throws -> ServerDetails {
        _ = try command(["stop", name])
        // HTTP settings live in the mounted config, so restarting is enough;
        // preserve the writable layer and avoid reinstalling agent dependencies.
        _ = try command(["start", name])
        try await waitUntilReady()
        return try management()
    }

    private func waitUntilReady() async throws {
        // Startup readiness, not a retry of failed operations. Surface the logs on timeout.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            // Readiness must not depend on the user's DNS, TLS proxy or host routing.
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(address.port!)/health/")!)
            request.timeoutInterval = 2
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) { return }
            } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
                throw error // A transport policy failure cannot heal while waiting for boot.
            } catch { /* The server may still be initializing its collection. */ }
            try await Task.sleep(for: .seconds(1))
        }
        throw ArchiveBoxError.message("ArchiveBox did not become ready.\n" + (try command(["logs", name], allowFailure: true)))
    }

    func stop() {
        guard ownsService,
              let output = try? command(["system", "status", "--format", "json"], logOutput: false),
              let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let path = (object["paths"] as? [String: String])?["appRoot"],
              URL(fileURLWithPath: path).standardizedFileURL == root.standardizedFileURL else { return }
        _ = try? command(["stop", name + "-init"], allowFailure: true, logOutput: false)
        _ = try? command(["stop", name], allowFailure: true)
        // Stop only this app’s workload. Other containers may have been added
        // through the terminal; do not terminate them when this app quits.
    }
}
