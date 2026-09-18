import Foundation

/// Read-only inventory. No login, ACL, Serve, or Funnel changes are made by discovery.
public struct TailscaleNetwork: Decodable, Sendable {
    public struct Device: Decodable, Sendable {
        public let DNSName: String?
        public let TailscaleIPs: [String]?
        public let Online: Bool?
        public var hostname: String? {
            guard let DNSName, !DNSName.isEmpty else { return nil }
            return DNSName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
    }
    public let BackendState: String
    public let `Self`: Device?
    public let Peer: [String: Device]?
    public var devices: [Device] { [Self].compactMap { $0 } + Array((Peer ?? [:]).values) }

    #if os(macOS)
    public static var executable: URL? {
        ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    public static func read() async throws -> Self {
        guard let executable else { throw ArchiveBoxError.message("Install and open Tailscale to discover tailnet devices.") }
        let result = try await ProcessCommand.runAsync(executable, ["status", "--json"], timeout: 8)
        guard result.status == 0 else { throw ArchiveBoxError.message("Tailscale’s device list is unavailable. Open Tailscale and connect, or paste device names below.") }
        let status = try JSONDecoder().decode(TailscaleNetwork.self, from: Data(result.output.utf8))
        guard status.BackendState == "Running" else { throw ArchiveBoxError.message("Tailscale is not connected. Open Tailscale, connect, and search again.") }
        return status
    }
    #endif
}
