import ArchiveBoxCore
import Foundation

// Acceptance against the companion's real container and host profiles.
// Never prints cookie values.
@main struct PersonaProfilesAcceptance {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else { throw ArchiveBoxError.message("Pass ArchiveBox Server.app's path, optionally followed by required browser names") }
        let runtime = Runtime(resources: URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: "Contents/Resources"))
        let json = try runtime.command(["inspect", runtime.name], logOutput: false)
        let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        guard let container = rows.first, runtime.hasCurrentBrowserProfileMounts(container) else {
            throw ArchiveBoxError.message("Container is missing the current read-only browser mounts. Relaunch the updated companion.")
        }
        guard !runtime.browserProfileMounts.isEmpty else {
            throw ArchiveBoxError.message("This acceptance check needs at least one installed Chromium browser profile.")
        }
        let output = try runtime.command([
            "exec", "--workdir", "/data", runtime.name, "/app/bin/docker_entrypoint.sh",
            "archivebox", "manage", "shell", "-c",
            "import json; from archivebox.personas.importers import discover_local_browser_profiles; print(json.dumps([{'browser': p.browser, 'root': str(p.user_data_dir), 'name': p.source_name} for p in discover_local_browser_profiles()]))",
        ], logOutput: false)
        guard let line = output.split(separator: "\n").last,
              let discovered = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[String: String]], !discovered.isEmpty else {
            throw ArchiveBoxError.message("Profile discovery did not return its results.")
        }
        let profiles = try HostBrowserProfile.discover()
        let marker = runtime.collectionDirectory.appendingPathComponent(".host-browser-personas.json")
        let before = try Data(contentsOf: marker)
        let seeds = try JSONDecoder().decode([String: String].self, from: before)
        for profile in profiles {
            guard seeds[profile.identifier] != nil, discovered.contains(where: { $0["name"] == profile.name && $0["browser"] == "persona" }) else {
                throw ArchiveBoxError.message("Missing portable profile: \(profile.name)")
            }
        }
        for browser in CommandLine.arguments.dropFirst(2) {
            guard profiles.contains(where: { $0.browser == browser }) else {
                throw ArchiveBoxError.message("Required browser was not discovered: \(browser)")
            }
        }
        try runtime.seedBrowserPersonas()
        guard try Data(contentsOf: marker) == before else { throw ArchiveBoxError.message("Repeated startup changed completed import records.") }
        print("PASS: \(profiles.count) host profiles seeded once, available as portable imports; read-only mounts present")
    }
}
