#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import ArchiveBoxCore

@Test func processesPreserveInputOutputAndExitStatus() throws {
    let input = Data("A small management request\n".utf8)
    let cat = try ProcessCommand.run(URL(fileURLWithPath: "/bin/cat"), [], input: input)
    #expect(cat.status == 0)
    #expect(Data(cat.output.utf8) == input)
    let failure = try ProcessCommand.run(URL(fileURLWithPath: "/bin/ls"), ["/archivebox-test-missing-\(UUID())"])
    #expect(failure.status != 0)
    #expect(failure.output.contains("No such file or directory"))
    // Pipe output larger than its capacity must drain without deadlocking or
    // truncating JSON, which can contain many users/processes on a real server.
    let large = String(repeating: "x", count: 100_000)
    let printed = try ProcessCommand.run(URL(fileURLWithPath: "/usr/bin/printf"), ["%s", large])
    #expect(printed.status == 0)
    #expect(printed.output == large)
}

@Test func cancellingACommandReapsItsChild() async throws {
    let pid = Mutex<Int32?>(nil)
    let task = Task {
        try await ProcessCommand.runAsync(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo $$; exec /bin/sleep 30"]) {
            if let value = Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) { pid.withLock { $0 = value } }
        }
    }
    defer { task.cancel() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while pid.withLock({ $0 == nil }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let child = try #require(pid.withLock { $0 })
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled command completed successfully") }
    catch is CancellationError { }
    #expect(kill(child, 0) == -1)
    #expect(errno == ESRCH)
}

@Test func keychainItemsAreIsolatedAndReplaceable() throws {
    let service = "io.archivebox.cleanup-test.\(UUID())"
    let first = KeychainItem(service: service, account: "first")
    let second = KeychainItem(service: service, account: "second")
    defer { try? first.clear(); try? second.clear() }
    #expect(try first.load() == nil)
    try first.save(Data("first value".utf8))
    try second.save(Data("second value".utf8))
    try first.save(Data("replacement".utf8))
    #expect(try first.load() == Data("replacement".utf8))
    #expect(try second.load() == Data("second value".utf8))
    try first.clear()
    #expect(try first.load() == nil)
    #expect(try second.load() != nil)
}
#endif
