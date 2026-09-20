import ArchiveBoxCore
import AppKit
import SwiftUI
import Vision

// Decode the actual default view with an available administrator key: its QR must
// remain address-only. Verify explicit admin links separately without exporting them.
@main struct ConnectionCodeAcceptance {
    @MainActor static func main() async throws {
        let runtime = Runtime(resources: URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: "Contents/Resources"))
        let status = try await TailscaleNetwork.read()
        guard let ip = status.Self?.TailscaleIPs?.first(where: { !$0.contains(":") }), let key = try runtime.browserAPIKey() else {
            throw ArchiveBoxError.message("Connect Tailscale and create an administrator first.")
        }
        let server = URL(string: "http://\(ip):5797")!
        let renderer = ImageRenderer(content: ConnectionCode(server: server, apiKey: key)
            .frame(width: 440).padding().background(.white))
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw ArchiveBoxError.message("Could not render connection QR.") }
        let decode = VNDetectBarcodesRequest()
        decode.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([decode])
        guard let payload = decode.results?.first?.payloadStringValue, let decoded = URL(string: payload),
              ConnectionLink.server(from: decoded) == server, ConnectionLink.apiKey(from: decoded) == nil else {
            throw ArchiveBoxError.message("Default QR must contain the connection address without an API key.")
        }
        let adminLink = ConnectionLink.make(server: server, apiKey: key)
        guard ConnectionLink.server(from: adminLink) == server, ConnectionLink.apiKey(from: adminLink) == key else {
            throw ArchiveBoxError.message("Explicit admin link did not preserve its credentials.")
        }
        let client = ArchiveBoxClient()
        let api = try await client.discoverServer(server.absoluteString)
        try await client.testToken(server: api, token: key)
        _ = try await client.browserSession(server: api, token: key)
        if CommandLine.arguments.count > 2 {
            let path = CommandLine.arguments[2]
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            guard FileManager.default.createFile(atPath: path, contents: png, attributes: [.posixPermissions: 0o600]) else {
                throw ArchiveBoxError.message("Could not write private connection QR.")
            }
        }
        print("PASS: displayed guest QR contains only the Tailscale address; explicit admin link, API authentication and browser sign-in succeeded")
    }
}
