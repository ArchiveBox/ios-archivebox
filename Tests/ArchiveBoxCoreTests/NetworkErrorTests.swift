import Foundation
import Darwin
import Testing
@testable import ArchiveBoxCore

@Test func refusedConnectionErrorCanCrossSecureCodingBoundary() async throws {
    // Reserve and release an ephemeral loopback port for a real refused
    // URLSession connection, without a test HTTP handler or external service.
    var socketFD = socket(AF_INET, SOCK_STREAM, 0)
    #expect(socketFD >= 0)
    defer { if socketFD >= 0 { close(socketFD) } }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try #require(bound == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
    }
    try #require(result == 0)
    close(socketFD)
    socketFD = -1
    let server = try #require(URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"))
    do {
        _ = try await ArchiveBoxClient().snapshots(configuration: ServerConfiguration(server: server, token: ""))
        Issue.record("A connection to a port without a listener must fail")
    } catch {
        let error = error as NSError
        #expect(error.domain == NSURLErrorDomain)
        #expect(error.code == URLError.cannotConnectToHost.rawValue)
        // Fail before invoking the encoder, which raises an Objective-C
        // exception for Network.__NWPath in an unsanitized URLSession error.
        try #require(Set(error.userInfo.keys) == [NSLocalizedDescriptionKey])
        let data = try NSKeyedArchiver.archivedData(withRootObject: error, requiringSecureCoding: true)
        let decoded = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: data))
        #expect(decoded.domain == error.domain)
        #expect(decoded.code == error.code)
        #expect(decoded.localizedDescription == error.localizedDescription)
    }
}
