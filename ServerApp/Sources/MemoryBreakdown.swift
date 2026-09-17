import Foundation
import Darwin

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
                throw CommandFailure(message: "The kernel did not report a complete memory breakdown.")
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
