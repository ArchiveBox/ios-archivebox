#if os(macOS)
import SwiftUI
import Testing
import Vision
@testable import ArchiveBoxCore

@Test @MainActor func displayedConnectionCodesDefaultToGuestEvenWhenAnAdminKeyIsAvailable() throws {
    let server = URL(string: "http://100.100.10.20:5797")!
    for compact in [false, true] {
        let renderer = ImageRenderer(content: ConnectionCode(server: server, apiKey: "test-only-admin-key", compact: compact)
            .frame(width: compact ? 240 : 440).padding().background(.white))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let payload = try #require(request.results?.first?.payloadStringValue)
        let link = try #require(URL(string: payload))
        #expect(ConnectionLink.server(from: link) == server)
        #expect(ConnectionLink.apiKey(from: link) == nil)
        #expect(!payload.contains("test-only-admin-key"))
    }
}
#endif
