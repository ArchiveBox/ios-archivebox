import AppKit
import SwiftUI

struct MoreUsageMethods: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("More usage methods").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Web UI", systemImage: "globe").font(.headline)
                        if let admin = model.serverDetails?.admin {
                            Link(admin.absoluteString, destination: admin)
                        }
                        Text("Open the admin URL on any machine that can reach this server to use ArchiveBox via the web interface.")
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Filesystem", systemImage: "folder").font(.headline)
                        HStack {
                            Text(model.collectionDirectory.path).textSelection(.enabled)
                            Button("Open in Finder", systemImage: "folder") { NSWorkspace.shared.open(model.collectionDirectory) }
                        }
                        Text("Browse your archived files and data directly on disk.")
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("REST API", systemImage: "network").font(.headline)
                        if let api = model.serverDetails?.api.appending(path: "api/v1/") {
                            Link(api.absoluteString, destination: api)
                        }
                        HStack {
                            if let api = model.serverDetails?.api.appending(path: "api/v1/docs") {
                                Link("Server API docs", destination: api)
                                Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
                            }
                            Link("REST API wiki", destination: URL(string: "https://github.com/ArchiveBox/ArchiveBox/wiki/Setting-up-Authentication#rest-api")!)
                        }
                        Text("Use your API key to submit URLs, query your archive, and automate workflows from other apps.")
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("CLI", systemImage: "terminal").font(.headline)
                        Link("CLI usage wiki", destination: URL(string: "https://github.com/ArchiveBox/ArchiveBox/wiki/Usage#cli-usage")!)
                        Text("Click the Shell tab above to use the bundled CLI. To install it locally, run uv tool install archivebox or brew install archivebox. Run ArchiveBox commands from inside your data directory:")
                        Text("cd \(quotedDirectory)\narchivebox status").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("SQL", systemImage: "tablecells").font(.headline)
                        Text(model.collectionDirectory.appending(path: "index.sqlite3").path)
                            .textSelection(.enabled)
                        Link("SQL / SQLite usage wiki", destination: URL(string: "https://github.com/ArchiveBox/ArchiveBox/wiki/Usage#sql-shell-usage")!)
                        Text("Query index.sqlite3 in your data directory directly, or run sqlite3 index.sqlite3 from that directory.")
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("MCP", systemImage: "sparkles").font(.headline)
                        Text("After installing the local CLI, run these commands in Terminal to connect Claude Code to this collection. Then open Claude Code and use /mcp to check the connection. ArchiveBox exposes its CLI commands as local stdio tools.")
                        Text("cd \(quotedDirectory)\nclaude mcp add --transport stdio archivebox -- archivebox mcp\nclaude")
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            Link("ArchiveBox MCP docs", destination: URL(string: "https://github.com/ArchiveBox/ArchiveBox/blob/dev/archivebox/mcp/README.md")!)
                            Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
                            Link("Claude Code setup", destination: URL(string: "https://code.claude.com/docs/en/mcp")!)
                            Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
                            Link("Codex Setup", destination: URL(string: "https://developers.openai.com/codex/mcp")!)
                            Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
                            Link("archivebox SKILL.md", destination: URL(string: "https://raw.githubusercontent.com/ArchiveBox/ArchiveBox/dev/skills/archivebox/SKILL.md")!)
                            Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
                            Link("abx-dl SKILL.md", destination: URL(string: "https://raw.githubusercontent.com/ArchiveBox/abx-dl/main/skills/abx-dl/SKILL.md")!)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }

    // Shell quoting keeps the copyable commands valid for paths containing spaces or apostrophes.
    private var quotedDirectory: String { "'" + model.collectionDirectory.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
