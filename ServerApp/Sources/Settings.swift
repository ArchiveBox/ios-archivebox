import AppKit
import SwiftUI
import SwiftTerm
import ArchiveBoxCore

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings").font(.largeTitle.bold())
                if model.serverDetails != nil && !model.hasAdmin {
                    AddSuperuserView(model: model, onboarding: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(model.state, systemImage: model.ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .foregroundStyle(model.ready ? Color.green : Color.secondary)
                            Spacer()
                            metric("CPU", model.cpu)
                            Spacer()
                            metric("Processes", model.processes)
                        }
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                            memoryRow("macOS App", model.memory.app)
                            memoryRow("Server memory", model.memory.container)
                            memoryRow("File cache (reclaimable)", model.memory.cache, muted: true)
                                .help("Linux can reclaim most file cache when other processes need memory.")
                        }
                        if let error = model.memory.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                        if !model.detail.isEmpty {
                            Text(model.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Divider()
                        ServerUpdateView()
                    }.padding(8)
                } label: {
                    HStack {
                        Label("Container", systemImage: "shippingbox")
                        Spacer()
                        Button("Restart", systemImage: "arrow.clockwise") { model.restartContainer() }
                            .disabled(!model.ready || model.managementBusy || model.restarting)
                            .help("Restart the container using its saved settings.")
                        Button("Stop & Quit", systemImage: "power") { NSApp.terminate(nil) }
                            .help("Shut down the server and quit ArchiveBox Server.")
                    }.buttonStyle(.glass)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Size on disk: \(model.disk)")
                            Button("Refresh", systemImage: "arrow.clockwise") { model.refreshSize() }
                                .labelStyle(.iconOnly).help("Refresh collection disk usage")
                            Spacer()
                            if model.hasAdmin, let shortcuts = model.serverDetails?.shortcuts {
                                Button("Personas", systemImage: "person.crop.circle") { model.openAdmin?(shortcuts.personas) }
                            }
                            Button("Open in Finder", systemImage: "folder") {
                                NSWorkspace.shared.open(model.collectionDirectory)
                            }
                            Button("Choose a path…", systemImage: "folder.badge.plus") { model.chooseCollection() }
                                .disabled(!model.runtime.ownsService || model.managementBusy || model.restarting)
                        }
                        if let error = model.collectionError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                        Text(model.collectionDirectory.path)
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }.padding(8)
                } label: { Label("Collection", systemImage: "externaldrive") }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        if let details = model.serverDetails {
                            connection("BASE_URL", details.base)
                            connection("Admin", details.admin)
                            connection("API", details.api)
                        } else {
                            Text(model.ready ? "Loading connection details…" : "Available when the server is running.")
                                .foregroundStyle(.secondary)
                        }
                        if let url = model.tailscaleURL {
                            Divider()
                            connection("Tailscale", url)
                        }
                        if let error = model.tailscaleError { Text(error).font(.caption).foregroundStyle(.secondary) }
                        Divider()
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("BASE_URL: Use the URL clients will visit. HTTPS requires a TLS proxy; custom hostnames require DNS. This does not change the local listener at 127.0.0.1:18080. Subdomain mode also requires admin, api, web and snapshot subdomains.")
                                    .font(.caption).foregroundStyle(.secondary)
                                TextField("BASE_URL", text: $model.baseURLDraft, prompt: Text("http://archivebox.localhost:18080"))
                                    .textFieldStyle(.roundedBorder)
                                Picker("SERVER_SECURITY_MODE", selection: $model.securityModeDraft) {
                                    ForEach(model.serverDetails?.securityModes ?? ["auto"], id: \.self) { Text($0).tag($0) }
                                }
                                if model.securityModeDraft == "unsafe-onedomain-noadmin" {
                                    Text("This mode disables the web admin UI, including Archive’s admin shortcuts and Activity.").font(.caption).foregroundStyle(.secondary)
                                } else if model.securityModeDraft == "danger-onedomain-fullreplay" {
                                    Text("Archived pages can execute scripts on the same origin as the admin UI in this mode.").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button("Apply & Restart") { model.restartContainer(savingHTTPSettings: true) }
                                        .disabled(!model.ready || model.managementBusy || model.restarting || !model.httpChanged)
                                    if model.restarting { ProgressView().controlSize(.small) }
                                    if let message = model.httpMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
                                }
                                if let error = model.httpError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                            }.padding(8)
                                .disabled(model.restarting)
                        } label: { Label("HTTP, TLS, and DNS", systemImage: "network.badge.shield.half.filled") }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                } label: {
                    HStack {
                        Label("Connection", systemImage: "network")
                        Spacer()
                        if model.hasAdmin, let shortcuts = model.serverDetails?.shortcuts {
                            Button("Server Settings", systemImage: "building.columns") { model.openAdmin?(shortcuts.host) }
                                .buttonStyle(.glass)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 760, minHeight: 650)
        .disabled(model.restarting)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private func connection(_ label: String, _ url: URL) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Link(url.absoluteString, destination: url).textSelection(.enabled)
            Spacer()
            Button("Copy \(label)", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }.labelStyle(.iconOnly).buttonStyle(.borderless)
        }
    }
    private func memoryRow(_ label: String, _ bytes: Int64?, muted: Bool = false) -> some View {
        GridRow {
            Text(label)
            Text(memorySize(bytes)).monospacedDigit().gridColumnAlignment(.trailing)
        }.foregroundStyle(muted ? .secondary : .primary)
    }

    private func memorySize(_ bytes: Int64?) -> String {
        bytes.map { String(format: "%.0f MB", Double($0) / 1_048_576) } ?? "—"
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .monospaced)).monospacedDigit()
        }
    }
}

struct ShellView: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Container Terminal", systemImage: "terminal").font(.headline)
                Spacer()
                if !model.terminalConnected {
                    Text("Disconnected").foregroundStyle(.secondary)
                    Button("Connect") { model.connectTerminal() }.disabled(!model.ready)
                }
                if model.hasAdmin, let shortcuts = model.serverDetails?.shortcuts {
                    Button("Debug Logs", systemImage: "doc.text") { model.openAdmin?(shortcuts.logs) }
                }
            }
            if let error = model.collectionError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("cd \(collectionShellPath); archivebox help")
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            EmbeddedTerminal(terminal: model.terminal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
                .accessibilityLabel("Container terminal")
                // Mounting SwiftTerm only draws a cursor; it does not launch a
                // shell. Connect once ready, without stealing form focus.
                .onChange(of: model.ready && !model.restarting, initial: true) { _, available in
                    if available { model.connectTerminal(focus: false) }
                }
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 650)
        .disabled(model.restarting && !model.changingCollection)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private var collectionShellPath: String {
        // The macOS collection path contains spaces; quote it for a pasted shell command.
        "'" + model.collectionDirectory.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

}

struct UsersView: View {
    @ObservedObject var model: SettingsModel
    @State private var addingUser = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("\(model.serverDetails?.users.count ?? 0) users").foregroundStyle(.secondary)
                            Spacer()
                            if model.managementBusy { ProgressView().controlSize(.small) }
                            Button("Refresh", systemImage: "arrow.clockwise") { model.refreshDetails() }
                                .disabled(!model.ready || model.managementBusy)
                            if model.hasAdmin { Button("Add superuser", systemImage: "person.badge.plus") {
                                model.managementError = nil; addingUser = true
                            }.disabled(!model.ready || model.managementBusy) }
                            if model.hasAdmin, let shortcuts = model.serverDetails?.shortcuts {
                                Button("API Keys", systemImage: "key") { model.openAdmin?(shortcuts.api) }
                            }
                        }
                        if let users = model.serverDetails?.users, !users.isEmpty {
                            Table(users) {
                                TableColumn("Username", value: \.username)
                                TableColumn("Email", value: \.email)
                                TableColumn("Role") { user in Text(user.is_superuser ? "Superuser" : user.is_staff ? "Staff" : "User") }
                                TableColumn("Status") { user in Text(!user.is_active ? "Inactive" : user.has_password ? "Active" : "No password") }
                            }.frame(height: CGFloat(min(users.count, 6) * 28 + 32))
                        } else if model.serverDetails != nil {
                            Text("No users yet. Add a superuser to sign in to the admin UI.").foregroundStyle(.secondary)
                        }
                        if let error = model.managementError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    }.padding(8)
                } label: { Label("Users", systemImage: "person.2") }
                ClientsView()
                MoreUsageMethods(model: model)
            }.padding(24)
        }
        .frame(minWidth: 760, minHeight: 650)
        .disabled(model.restarting)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $addingUser) { AddSuperuserView(model: model) }
    }
}

private struct AddSuperuserView: View {
    @ObservedObject var model: SettingsModel
    var onboarding = false
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var error: String?
    @FocusState private var focusedUsername: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(onboarding ? "Create your first admin" : "Add superuser").font(.title2.bold())
            Text("Create an administrator for this local ArchiveBox server.").foregroundStyle(.secondary)
            Form {
                TextField("Username", text: $username).focused($focusedUsername)
                TextField("Email (optional)", text: $email)
                SecureField("Password", text: $password)
                SecureField("Confirm password", text: $confirmation)
            }.textFieldStyle(.roundedBorder).disabled(model.managementBusy)
            if !confirmation.isEmpty && password != confirmation {
                Text("Passwords don’t match.").foregroundStyle(.red)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                if !onboarding { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.managementBusy) }
                Button("Create superuser") {
                    Task {
                        if await model.updateUsers(username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) {
                            password = ""; confirmation = ""; if !onboarding { dismiss() }
                        } else { error = model.managementError }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(!model.ready || model.managementBusy || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || password != confirmation)
            }
        }.padding(onboarding ? 0 : 24).frame(maxWidth: 500)
            .interactiveDismissDisabled(model.managementBusy)
            .task { if !model.managementBusy { focusedUsername = true } }
            .onChange(of: model.managementBusy) { _, busy in
                if !busy && username.isEmpty { focusedUsername = true }
            }
            .onDisappear { password = ""; confirmation = "" }
    }
}
