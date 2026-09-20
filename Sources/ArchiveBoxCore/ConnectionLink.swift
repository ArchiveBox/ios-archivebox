import Foundation
import SwiftUI
import CoreImage.CIFilterBuiltins
#if os(macOS)
import AppKit
#endif

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
    private let isVisible: Bool
    @State private var adminQRExpiresAt: Date?
    @State private var showingAdminShare = false
    #if !os(macOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif
    public init(server: URL, apiKey: String? = nil, compact: Bool = false, isVisible: Bool = true) {
        self.server = server; self.apiKey = apiKey; self.compact = compact; self.isVisible = isVisible
    }
    private var hasAdminKey: Bool { apiKey?.isEmpty == false }
    private var showingAdminQR: Bool {
        isVisible && hasAdminKey && adminQRExpiresAt.map { $0 > Date() } == true
    }
    private let adminWarning = "This signs a mobile device in using your admin account. Do not share with anyone else: they will be able to control your server."
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your iPhone").font(compact ? .caption.bold() : .headline)
            if !compact {
                Text("Scan with your iPhone’s Camera to connect in ArchiveBox. Keep Tailscale connected on both devices.")
            }
            Menu {
                Button("Guest QR code", systemImage: "person.crop.circle") { adminQRExpiresAt = nil }
                Button("Show admin QR code", systemImage: "exclamationmark.shield") {
                    adminQRExpiresAt = Date().addingTimeInterval(60)
                }.disabled(!hasAdminKey)
            } label: {
                Label(showingAdminQR ? "Admin QR code" : "Guest QR code",
                      systemImage: showingAdminQR ? "exclamationmark.shield" : "person.crop.circle")
            }
            .accessibilityIdentifier("connection.qrMode")
            if showingAdminQR {
                Text("Scanning this code signs a mobile device in using your admin account. Do not share with anyone else: they will be able to control your server.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connection.adminWarning")
            }
            if let code = code {
                Image(decorative: code, scale: 1).resizable().interpolation(.none).scaledToFit()
                    .frame(width: compact ? 144 : 200, height: compact ? 144 : 200).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("\(showingAdminQR ? "Admin" : "Guest") connection QR code for \(server.absoluteString)")
                    .accessibilityIdentifier("connection.qr")
            }
            if showingAdminQR { Text("Returns to guest QR after 60 seconds.").font(.caption).foregroundStyle(.secondary) }
            if compact { Text("Scan with Camera").font(.caption).foregroundStyle(.secondary) }
            else { Text(server.absoluteString).font(.callout.monospaced()).textSelection(.enabled) }
            Menu {
                ShareLink(item: ConnectionLink.make(server: server)) {
                    Label("Link phone to this server as a guest", systemImage: "person.crop.circle")
                }
                Button("Link phone to this server as an admin", systemImage: "exclamationmark.shield") {
                    adminQRExpiresAt = nil
                    showingAdminShare = true
                }.disabled(!hasAdminKey)
            } label: {
                Text("Send an instant-login link to your phone").fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("connection.share")
        }
        .task(id: adminQRExpiresAt) {
            guard let deadline = adminQRExpiresAt else { return }
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            if adminQRExpiresAt == deadline { adminQRExpiresAt = nil }
        }
        .onDisappear { reset() }
        .onChange(of: isVisible) { _, visible in if !visible { reset() } }
        .onChange(of: server) { _, _ in reset() }
        .onChange(of: apiKey) { _, _ in reset() }
        #if os(macOS)
        // Also works in the companion's AppKit-hosted windows, outside a SwiftUI scene.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in adminQRExpiresAt = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in adminQRExpiresAt = nil }
        #else
        .onChange(of: scenePhase) { _, phase in if phase != .active { reset() } }
        #endif
        .sheet(isPresented: $showingAdminShare) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Link phone as an admin", systemImage: "exclamationmark.shield").font(.headline)
                Text(adminWarning)
                if let apiKey, !apiKey.isEmpty, isVisible {
                    ShareLink("Send admin login link", item: ConnectionLink.make(server: server, apiKey: apiKey))
                        .accessibilityIdentifier("connection.shareAdmin")
                }
                Button("Cancel", role: .cancel) { showingAdminShare = false }
            }.padding(24).frame(idealWidth: 400)
        }
    }
    private func reset() { adminQRExpiresAt = nil; showingAdminShare = false }
    private var code: CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(ConnectionLink.make(server: server, apiKey: showingAdminQR ? apiKey : nil).absoluteString.utf8)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
