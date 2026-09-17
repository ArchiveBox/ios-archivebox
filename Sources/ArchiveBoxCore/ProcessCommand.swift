#if os(macOS)
import Foundation
import Synchronization
import Darwin

// A cancelled Process task must terminate and reap the real child, not just stop
// awaiting it. Keep pipe draining off the main actor so downloads cannot freeze UI.
public enum ProcessCommand {
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

    public static func runAsync(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 900,
                                progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Result {
        let child = Child()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try run(executable, arguments, input: nil, timeout: timeout, outputLimit: 65536,
                        child: child, progress: progress)
            }.value
        } onCancel: { child.cancel() }
    }

    /// Synchronous commands run on the companion's background tasks. Preserve full
    /// JSON output; only interactive download diagnostics need a bounded tail.
    public static func run(_ executable: URL, _ arguments: [String], input: Data? = nil) throws -> Result {
        try run(executable, arguments, input: input, timeout: nil, outputLimit: nil, child: Child(), progress: { _ in })
    }

    private static func run(_ executable: URL, _ arguments: [String], input: Data?, timeout: TimeInterval?,
                            outputLimit: Int?, child: Child, progress: @Sendable (String) -> Void) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
        try child.state.withLock { state in
            if state.cancelled { throw CancellationError() }
            try process.run()
            state.process = process
        }
        let timer = timeout.map { timeout in
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { child.cancel() }
            timer.resume()
            return timer
        }
        defer {
            timer?.cancel()
            if process.isRunning { child.cancel() }
            process.waitUntilExit()
            child.state.withLock { $0.process = nil }
        }
        if let input {
            // Management credentials travel through stdin, never command arguments
            // or logs. Callers pass small JSON documents, not streaming input.
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        }
        var tail = Data()
        // availableData returns each pipe chunk immediately; read(upToCount:) can
        // wait for a full buffer, hiding progress from a still-running process.
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            tail.append(data)
            if let outputLimit, tail.count > outputLimit { tail.removeFirst(tail.count - outputLimit) }
            progress(String(decoding: data, as: UTF8.self))
        }
        process.waitUntilExit()
        let cancelled = child.state.withLock { state in
            state.process = nil
            return state.cancelled
        }
        if cancelled { throw CancellationError() }
        return Result(status: process.terminationStatus, output: String(decoding: tail, as: UTF8.self))
    }
}
#endif
