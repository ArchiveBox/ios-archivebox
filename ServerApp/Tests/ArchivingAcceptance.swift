import Foundation

// Real CLI-created crawls in an idle companion collection. Never pause or resume
// someone else's work: refuse to run when any active/paused crawl already exists.
@main struct ArchivingAcceptance {
    static func check(_ condition: Bool, line: Int = #line) throws {
        if !condition { throw CommandFailure(message: "Archiving assertion failed at line \(line)") }
    }
    static func main() throws {
        let runtime = Runtime(resources: URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: "Contents/Resources"))
        let before = try runtime.archiving()
        try check(before.active == 0 && before.paused == 0)
        let marker = "menu-acceptance-" + UUID().uuidString
        func cli(_ args: [String], input: Data? = nil) throws -> String {
            try runtime.command(["exec", "--interactive", "--workdir", "/data", runtime.name,
                                 "/app/bin/docker_entrypoint.sh", "archivebox", "crawl"] + args, logOutput: false, input: input)
        }
        func rows(_ output: String) -> Data {
            Data((output.split(separator: "\n").filter { $0.hasPrefix("{") }.joined(separator: "\n") + "\n").utf8)
        }
        defer {
            do {
                let own = try cli(["list", "--urls__icontains", marker])
                _ = try cli(["delete", "--yes"], input: rows(own))
            } catch { print("Cleanup failed for \(marker): \(error)") }
        }
        let sealedJob = try cli(["create", "https://example.com/?\(marker)-sealed"])
        _ = try cli(["update", "--status", "sealed"], input: rows(sealedJob))
        _ = try cli(["create", "https://example.com/?\(marker)-active"])
        let paused = try runtime.archiving(action: "pause")
        FileHandle.standardError.write(Data("pause: changed=\(paused.changed) paused=\(paused.paused) active=\(paused.active)\n".utf8))
        try check(paused.changed == 1 && paused.paused == 1 && paused.active == 0)
        let resumed = try runtime.archiving(action: "resume")
        try check(resumed.changed == 1 && resumed.paused == 0)
        let sealed = try cli(["list", "--status", "sealed", "--urls__icontains", "\(marker)-sealed"])
        try check(String(data: rows(sealed), encoding: .utf8)!.contains("\(marker)-sealed"))
        print("PASS: active crawl paused, paused crawl resumed, sealed crawl unchanged; temporary crawls cleaned up")
    }
}
