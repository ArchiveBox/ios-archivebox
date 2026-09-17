#if os(macOS)
import Foundation
import Synchronization
import Darwin

public struct EngineFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// A cancelled Process task must terminate and reap the real child, not just stop
// awaiting it. Keep pipe draining off the main actor so downloads cannot freeze UI.
public enum EngineCommand {
    public struct Result: Sendable { public let status: Int32; public let output: String }
    private final class Child: Sendable {
        struct State { var process: Process?; var cancelled = false }
        let state = Mutex(State())
        func cancel() {
            state.withLock { state in
                state.cancelled = true
                if let process = state.process, process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                state.withLock { state in
                    if let process = state.process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    public static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 900,
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Result {
        let child = Child()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = ProcessInfo.processInfo.environment.merging([
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "NO_COLOR": "1", "TERM": "dumb"
                ]) { _, new in new }
                let pipe = Pipe()
                process.standardOutput = pipe; process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                try child.state.withLock { state in
                    if state.cancelled { throw CancellationError() }
                    try process.run()
                    state.process = process
                }
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler { child.cancel() }
                timer.resume()
                defer { timer.cancel() }
                var tail = Data()
                while let data = try pipe.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
                    tail.append(data)
                    if tail.count > 65536 { tail.removeFirst(tail.count - 65536) }
                    progress(String(decoding: data, as: UTF8.self))
                }
                process.waitUntilExit()
                let cancelled = child.state.withLock { state in
                    state.process = nil
                    return state.cancelled
                }
                if cancelled { throw CancellationError() }
                return Result(status: process.terminationStatus, output: String(decoding: tail, as: UTF8.self))
            }.value
        } onCancel: { child.cancel() }
    }
}

final class ToolsetDownload: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: @Sendable (Int64, Int64) -> Void
    init(progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
#endif
