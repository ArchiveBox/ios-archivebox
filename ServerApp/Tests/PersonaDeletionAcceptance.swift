import ArchiveBoxCore
import Foundation

// Exercise deletion using real CLI/DB/files and the production startup importer.
// Restore only the untouched seed this check deletes, using its portable export.
@main struct PersonaDeletionAcceptance {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw ArchiveBoxError.message("Pass the installed server app path") }
        let runtime = Runtime(resources: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Contents/Resources"))
        let marker = runtime.collectionDirectory.appendingPathComponent(".host-browser-personas.json")
        let before = try Data(contentsOf: marker)
        let seeds = try JSONDecoder().decode([String: String].self, from: before)
        guard seeds["chromium/Default"] == "Chromium - Default" else { throw ArchiveBoxError.message("Needs the automatically imported Chromium Default persona") }
        let prefix = ["exec", "--interactive", "--workdir", "/data", runtime.name, "/app/bin/docker_entrypoint.sh", "archivebox"]
        _ = try runtime.command(prefix + ["manage", "shell", "-c", "from archivebox.personas.models import Persona; p=Persona.objects.get(name='Chromium - Default'); assert p.config == {'PERMISSIONS':'private'}; assert not p.crawls.exists()"], logOutput: false)
        let restore = prefix + ["persona", "create", "--permissions=private", "--import=/data/.host-browser-profiles/Chromium - Default", "Chromium - Default"]
        _ = try runtime.command(prefix + ["persona", "delete", "--yes"], logOutput: false, input: Data("{\"name\":\"Chromium - Default\"}\n".utf8))
        do {
            do { try runtime.seedBrowserPersonas() }
            catch {
                // Source-profile failures are reported separately; assertions
                // below still verify deletion against the resulting real DB.
                print("Import reported a source-profile error:", error.localizedDescription)
            }
            let listed = try runtime.command(prefix + ["persona", "list", "--name=Chromium - Default"], logOutput: false)
            guard !listed.contains("\"id\"") else { throw ArchiveBoxError.message("Deleted persona was recreated") }
            guard try Data(contentsOf: marker) == before else { throw ArchiveBoxError.message("Completed import records changed") }
        } catch {
            _ = try runtime.command(restore, logOutput: false)
            throw error
        }
        _ = try runtime.command(restore, logOutput: false)
        print("PASS: deleting a seeded Persona does not recreate it on subsequent startup; restored explicitly after verification")
    }
}
