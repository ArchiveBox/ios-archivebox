import Foundation
import SwiftUI
import CoreImage.CIFilterBuiltins

public enum ConnectionLink {
    public static func make(server: URL, apiKey: String? = nil) -> URL {
        var link = URLComponents()
        link.scheme = "archivebox"; link.host = "connect"
        link.queryItems = [URLQueryItem(name: "server", value: server.absoluteString)]
        if let apiKey, !apiKey.isEmpty { link.queryItems?.append(URLQueryItem(name: "api_key", value: apiKey)) }
        return link.url!
    }
    public static func apiKey(from link: URL) -> String? {
        guard server(from: link) != nil else { return nil }
        return URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "api_key" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func server(from link: URL) -> URL? {
        guard link.scheme == "archivebox", link.host == "connect",
              let parts = URLComponents(url: link, resolvingAgainstBaseURL: false),
              let value = parts.queryItems?.first(where: { $0.name == "server" })?.value else { return nil }
        return try? ServerAddress.normalize(value)
    }
}

public struct ConnectionCode: View {
    private let server: URL
    private let compact: Bool
    private let apiKey: String?
    public init(server: URL, apiKey: String? = nil, compact: Bool = false) { self.server = server; self.apiKey = apiKey; self.compact = compact }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your iPhone").font(compact ? .caption.bold() : .headline)
            if !compact {
                Text("Scan with your iPhone’s Camera to connect in ArchiveBox. Keep Tailscale connected on both devices.")
            }
            if let code = code {
                Image(decorative: code, scale: 1).resizable().interpolation(.none).scaledToFit()
                    .frame(width: compact ? 144 : 200, height: compact ? 144 : 200).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Connection QR code for \(server.absoluteString)")
            }
            if compact { Text("Scan with Camera").font(.caption).foregroundStyle(.secondary) }
            else { Text(server.absoluteString).font(.callout.monospaced()).textSelection(.enabled) }
            ShareLink("Share connection link", item: ConnectionLink.make(server: server, apiKey: apiKey))
            if apiKey == nil && !compact {
                Text("The link contains the address only. Sign in to ArchiveBox to finish connecting.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var code: CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(ConnectionLink.make(server: server, apiKey: apiKey).absoluteString.utf8)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
