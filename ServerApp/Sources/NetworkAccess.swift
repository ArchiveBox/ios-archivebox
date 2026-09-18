import ArchiveBoxCore
import Foundation
import Darwin

struct NetworkOptions: Codable, Equatable {
    enum Certificate: String, CaseIterable, Codable {
        case tailscale = "Tailscale Serve / Funnel"
        case cloudflare = "Cloudflare HTTPS"
        case letsEncrypt = "Let’s Encrypt wildcard certificate"
        case own = "My own certificate…"
    }
    var lan = true
    var tailnet = true
    var internet = false
    var https = false
    var port = 5797
    var baseURL = ""
    var certificate = Certificate.tailscale
    var securityMode = "auto"
    var certificateFile = ""
    var privateKeyFile = ""
    var effectiveSecurityMode: String {
        if securityMode != "auto" { return securityMode }
        return "safe-onedomain-nojsreplay"
    }
    static func load() -> Self {
        UserDefaults.standard.data(forKey: "networkAccessOptions").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "networkAccessOptions") }
}

/// One app-owned Caddy process. It binds only the requested interface addresses;
/// the existing container's localhost listener and other Caddy installs stay intact.
@MainActor final class NetworkAccess {
    private var process: Process?
    private var log: FileHandle?
    private(set) var urls: [URL] = []
    private let runtime: Runtime
    init(runtime: Runtime) { self.runtime = runtime }

    static func lanAddresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        var result = Set<String>()
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  String(cString: item.pointee.ifa_name).hasPrefix("en") else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard value >> 24 == 10 || value >> 20 == 0xac1 || value >> 16 == 0xc0a8 else { continue }
            result.insert([24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: "."))
        }
        return result.sorted()
    }

    func start(options: NetworkOptions) async throws -> [URL] {
        guard (1024...65535).contains(options.port) else { throw ArchiveBoxError.message("Choose a listen port between 1024 and 65535.") }
        var hosts = options.lan ? Self.lanAddresses() : []
        if options.tailnet {
            let network = try await TailscaleNetwork.read()
            guard let ip = network.Self?.TailscaleIPs?.first(where: { !$0.contains(":") }) else { throw ArchiveBoxError.message("Tailscale is not connected.") }
            hosts.insert(ip, at: 0)
        }
        if options.port != 5797 { hosts.append("127.0.0.1") }
        guard !hosts.isEmpty else { await stop(); return [] }
        let binary = runtime.resources.appending(path: "caddy")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw ArchiveBoxError.message("The bundled network helper is missing. Reinstall ArchiveBox Server.") }
        let directory = runtime.home.appending(path: "network")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appending(path: "caddy.json")
        var server: [String: Any] = [
            "listen": hosts.map { "\($0):\(options.port)" },
            "automatic_https": ["disable": true],
            "routes": [["handle": [["handler": "reverse_proxy", "upstreams": [["dial": "127.0.0.1:5797"]]]]]]
        ]
        var apps: [String: Any] = [:]
        // Tailscale terminates HTTPS itself; LAN addresses remain local HTTP
        // endpoints. Imported certificates terminate at the interface listeners.
        let localTLS = options.https && options.certificate == .own
        if localTLS {
            guard !options.certificateFile.isEmpty, !options.privateKeyFile.isEmpty else { throw ArchiveBoxError.message("Choose a certificate chain and private key first.") }
            server["tls_connection_policies"] = [[:]] as [[String: String]]
            apps["tls"] = ["certificates": ["load_files": [["certificate": options.certificateFile, "key": options.privateKeyFile]]]]
        }
        apps["http"] = ["servers": ["archivebox": server]]
        let document: [String: Any] = ["admin": ["disabled": true], "apps": apps]
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: config, options: .atomic)
        let check = try await ProcessCommand.runAsync(binary, ["validate", "--config", config.path], timeout: 15)
        guard check.status == 0 else { throw ArchiveBoxError.message("Network settings could not be validated. Check your certificate and listen addresses.\n" + check.output) }
        await stop()
        let process = Process()
        process.executableURL = binary; process.arguments = ["run", "--config", config.path]
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_DATA_HOME"] = directory.path; environment["XDG_CONFIG_HOME"] = directory.path
        process.environment = environment
        let logURL = directory.appending(path: "network.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = handle; process.standardError = handle
        try process.run(); self.process = process; log = handle
        urls = hosts.compactMap { URL(string: "\(localTLS ? "https" : "http")://\($0):\(options.port)") }
        // Wait for Caddy's real listener readiness; do not report success on spawn.
        for _ in 0..<40 {
            guard process.isRunning else { throw ArchiveBoxError.message("The network listener stopped. Another app may be using that port. See network/network.log.") }
            let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if output.contains("server running") { return urls }
            try await Task.sleep(for: .milliseconds(100))
        }
        await stop()
        throw ArchiveBoxError.message("The network listener did not become ready. See network/network.log.")
    }
    func stop() async {
        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<30 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            await Task.detached { process.waitUntilExit() }.value
        }
        process = nil; try? log?.close(); log = nil; urls = []
    }
}
