import AppKit
import Darwin
import ArchiveBoxCore

struct ContainerSample: Sendable {
    var state: String
    var cpuUsec: Double?
    var memory: Int64?
    var processes: Int?
    var error: String?
    var time = ProcessInfo.processInfo.systemUptime
}

extension Runtime {
    func sample() -> ContainerSample {
        guard ownsService else { return ContainerSample(state: "unavailable", error: "ArchiveBox does not own a running container service.") }
        do {
            let output = try command(["list", "--all", "--format", "json"], logOutput: false)
            let rows = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] ?? []
            guard let row = rows.first(where: { $0["id"] as? String == name }) else {
                return ContainerSample(state: "stopped")
            }
            let state = (row["status"] as? [String: Any])?["state"] as? String ?? "unknown"
            guard state == "running" else { return ContainerSample(state: state) }
            let statsOutput = try command(["stats", "--no-stream", "--format", "json", name], logOutput: false)
            let stats = try JSONSerialization.jsonObject(with: Data(statsOutput.utf8)) as? [[String: Any]]
            guard let values = stats?.first else {
                return ContainerSample(state: state, error: "Runtime returned no resource statistics.")
            }
            return ContainerSample(state: state,
                cpuUsec: (values["cpuUsageUsec"] as? NSNumber)?.doubleValue,
                memory: (values["memoryUsageBytes"] as? NSNumber)?.int64Value,
                processes: (values["numProcesses"] as? NSNumber)?.intValue)
        } catch { return ContainerSample(state: "unavailable", error: error.localizedDescription) }
    }

    func collectionSize() throws -> String {
        let result = try command(["-sk", collectionDirectory.path], logOutput: false,
                                 executable: URL(fileURLWithPath: "/usr/bin/du"))
        guard let first = result.split(whereSeparator: { $0.isWhitespace }).first,
              let kib = Int64(first) else { throw ArchiveBoxError.message(result) }
        return ByteCountFormatter.string(fromByteCount: kib * 1024, countStyle: .file)
    }
}


struct MemoryBreakdown: Sendable {
    var app: Int64?
    var cache: Int64?
    var container: Int64?
    var kernel: Int64?
    var error: String?

}

extension Runtime {
    func memoryBreakdown() -> MemoryBreakdown {
        var result = MemoryBreakdown()
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if status == KERN_SUCCESS { result.app = Int64(info.resident_size) }
        guard ownsService else { return result }
        do {
            let output = try command(["exec", name, "cat", "/sys/fs/cgroup/memory.stat"], logOutput: false)
            let values = Dictionary(output.split(separator: "\n").compactMap { line -> (String, Int64)? in
                let fields = line.split(separator: " ")
                guard fields.count == 2, let bytes = Int64(fields[1]) else { return nil }
                return (String(fields[0]), bytes)
            }, uniquingKeysWith: { _, latest in latest })
            guard let anon = values["anon"], let file = values["file"], let shared = values["shmem"], let kernel = values["kernel"] else {
                throw ArchiveBoxError.message("The kernel did not report a complete memory breakdown.")
            }
            // memory.stat counts shared memory in file, but it is process memory,
            // not reclaimable disk cache. Keep these displayed categories disjoint.
            result.container = anon + shared
            result.cache = max(0, file - shared)
            result.kernel = kernel
        } catch { result.error = "Container memory breakdown unavailable." }
        return result
    }
}
