import ArchiveBoxCore
import AppKit
import CoreImage.CIFilterBuiltins
import Vision

// Decode a real QR and authenticate using the existing Mac administrator key.
// An optional output PNG is private and must never be checked into source control.
@main struct ConnectionCodeAcceptance {
    @MainActor static func main() async throws {
        let runtime = Runtime(resources: URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: "Contents/Resources"))
        let status = try await TailscaleNetwork.read()
        guard let ip = status.Self?.TailscaleIPs?.first(where: { !$0.contains(":") }), let key = try runtime.browserAPIKey() else {
            throw ArchiveBoxError.message("Connect Tailscale and create an administrator first.")
        }
        let server = URL(string: "http://\(ip):5797")!
        let link = ConnectionLink.make(server: server, apiKey: key)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.absoluteString.utf8)
        let output = filter.outputImage!
        let transform = CGAffineTransform(scaleX: 8, y: 8)
        let code = CIContext().createCGImage(output.transformed(by: transform), from: output.extent.applying(transform))!
        let size = code.width + 64
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.interpolationQuality = .none
        context.draw(code, in: CGRect(x: 32, y: 32, width: code.width, height: code.height))
        let image = context.makeImage()!
        let decode = VNDetectBarcodesRequest()
        decode.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([decode])
        guard let payload = decode.results?.first?.payloadStringValue, let decoded = URL(string: payload),
              ConnectionLink.server(from: decoded) == server, ConnectionLink.apiKey(from: decoded) == key else {
            throw ArchiveBoxError.message("QR did not preserve the connection address and key.")
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
        print("PASS: QR decoded the Tailscale address and existing administrator key; API authentication and browser sign-in succeeded")
    }
}
