import AppKit
import SwiftUI
import SwiftTerm

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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", home.appendingPathComponent("data").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let result = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let first = result.split(whereSeparator: { $0.isWhitespace }).first,
              let kib = Int64(first) else { throw CommandFailure(message: result) }
        return ByteCountFormatter.string(fromByteCount: kib * 1024, countStyle: .file)
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var state = "Starting"
    @Published var cpu = "—"
    @Published var ram = "—"
    @Published var processes = "—"
    @Published var disk = "Calculating…"
    @Published var detail = ""
    @Published var ready = false
    @Published var terminalConnected = false
    @Published var serverDetails: ServerDetails?
    @Published var managementBusy = false
    @Published var managementError: String?
    @Published var tailscaleURL: URL?
    @Published var tailscaleError: String?
    var hasAdmin: Bool { serverDetails?.hasAdmin == true }
    var didUpdateDetails: ((ServerDetails) async -> Void)?
    var openAdmin: ((URL) -> Void)?
    let runtime: Runtime
    let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 350))
    private var polling: Task<Void, Never>?
    private var sizing: Task<Void, Never>?
    private var loadingDetails: Task<Void, Never>?
    private var previous: ContainerSample?
    private var expectedRunning = false
    private var startupFinished = false
    private var startupError: String?
    private var lastSizeRefresh = Date.distantPast
    var terminalDelegate: TerminalDelegate!

    init(runtime: Runtime) {
        self.runtime = runtime
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeForegroundColor = .textColor
        terminal.nativeBackgroundColor = .textBackgroundColor
        terminalDelegate = TerminalDelegate(model: self)
        terminal.processDelegate = terminalDelegate
    }

    func didStart(error: String? = nil) {
        startupFinished = true
        startupError = error
        expectedRunning = error == nil
        state = error == nil ? "Running" : "Failed to start"
        ready = error == nil
        detail = error ?? ""
        if ready, polling != nil { refreshDetails() }
    }

    func monitor() {
        guard polling == nil else { return }
        refreshSize()
        refreshDetails()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if Date().timeIntervalSince(lastSizeRefresh) >= 30 { refreshSize(); refreshDetails() }
                if startupFinished {
                    let value = await Task.detached { [runtime] in runtime.sample() }.value
                    if Task.isCancelled { return }
                    apply(value)
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func pauseMonitoring() { polling?.cancel(); polling = nil; previous = nil }

    private func apply(_ sample: ContainerSample) {
        ready = sample.state == "running"
        if ready {
            state = "Running"
            detail = sample.error ?? "CPU: 100% = one core · RAM is container usage, not total host VM memory."
        } else if expectedRunning {
            state = "Crashed / stopped unexpectedly"
            detail = sample.error ?? "The container was running but is now \(sample.state). The runtime does not report an exit reason."
        } else {
            state = startupError == nil ? "Stopped" : "Failed to start"
            detail = startupError ?? sample.error ?? ""
        }
        cpu = "—"
        if ready, let before = previous, before.state == "running",
           let old = before.cpuUsec, let now = sample.cpuUsec, now >= old, sample.time > before.time {
            cpu = String(format: "%.1f%%", (now - old) / 1_000_000 / (sample.time - before.time) * 100)
        }
        ram = sample.memory.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "—"
        processes = sample.processes.map(String.init) ?? "—"
        previous = sample
    }

    func refreshSize() {
        guard sizing == nil else { return }
        lastSizeRefresh = Date()
        sizing = Task {
            do { disk = try await Task.detached { [runtime] in try runtime.collectionSize() }.value }
            catch { disk = "Unavailable" }
            sizing = nil
        }
    }

    func refreshDetails() {
        guard ready, loadingDetails == nil, !managementBusy else { return }
        loadingDetails = Task {
            _ = await updateUsers()
            do {
                tailscaleURL = try await Task.detached { [runtime] in
                    try runtime.tailscaleAddress(port: runtime.address.port!)
                }.value
                tailscaleError = nil
            } catch {
                tailscaleURL = nil
                tailscaleError = "Couldn’t read Tailscale status."
            }
            loadingDetails = nil
        }
    }

    func updateUsers(username: String? = nil, email: String = "", password: String = "") async -> Bool {
        guard ready, !managementBusy else { return false }
        managementBusy = true; managementError = nil
        defer { managementBusy = false }
        do {
            serverDetails = try await Task.detached { [runtime] in
                try runtime.management(username: username, email: email, password: password)
            }.value
            if let serverDetails { await didUpdateDetails?(serverDetails) }
            return true
        } catch {
            managementError = error.localizedDescription
            return false
        }
    }

    func connectTerminal() {
        guard ready, !terminalConnected else { return }
        terminalConnected = true
        // The existing image entrypoint selects its writable unprivileged user and
        // environment. A PTY on both sides preserves password prompts and signals.
        terminal.startProcess(executable: runtime.cli.path,
            args: ["exec", "--interactive", "--tty", "--env", "TERM=xterm-256color",
                   "--workdir", "/data", runtime.name, "/app/bin/docker_entrypoint.sh",
                   "/bin/bash", "--noprofile", "--norc", "-i"],
            environment: ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" })
        terminal.window?.makeFirstResponder(terminal)
    }

    func shutdown() { pauseMonitoring(); sizing?.cancel(); terminal.terminate() }
}

final class TerminalDelegate: LocalProcessTerminalViewDelegate {
    weak var model: SettingsModel?
    init(model: SettingsModel) { self.model = model }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in self?.model?.terminalConnected = false }
    }
}

struct EmbeddedTerminal: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    func makeNSView(context: Context) -> LocalProcessTerminalView { terminal }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var addingUser = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings").font(.largeTitle.bold())
                if model.serverDetails != nil && !model.hasAdmin {
                    AddSuperuserView(model: model, onboarding: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.hasAdmin, let shortcuts = model.serverDetails?.shortcuts {
                    HStack {
                        Button("🏛️ Server Settings") { model.openAdmin?(shortcuts.host) }
                        Button("👤 Personas") { model.openAdmin?(shortcuts.personas) }
                        Button("🔐 API Keys & Webhooks") { model.openAdmin?(shortcuts.api) }
                        Button("📜 Debug Logs") { model.openAdmin?(shortcuts.logs) }
                    }.buttonStyle(.glass)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(model.state, systemImage: model.ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .foregroundStyle(model.ready ? Color.green : Color.secondary)
                            Spacer()
                            metric("CPU", model.cpu)
                            Spacer()
                            metric("RAM", model.ram)
                            Spacer()
                            metric("Processes", model.processes)
                        }
                        Text(model.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(8)
                } label: { Label("Container", systemImage: "shippingbox") }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Size on disk: \(model.disk)")
                            Button("Refresh", systemImage: "arrow.clockwise") { model.refreshSize() }
                                .labelStyle(.iconOnly).help("Refresh collection disk usage")
                            Spacer()
                            Button("Open in Finder", systemImage: "folder") {
                                NSWorkspace.shared.open(model.runtime.home.appendingPathComponent("data"))
                            }
                        }
                        Text(model.runtime.home.appendingPathComponent("data").path)
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
                            Text("Tailscale is connected. This server listens only on localhost; this address needs a Tailscale proxy before other devices can use it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = model.tailscaleError { Text(error).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                } label: { Label("Connection", systemImage: "network") }
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
                HStack {
                    Label("Container Terminal", systemImage: "terminal").font(.headline)
                    Spacer()
                    Text(model.terminalConnected ? "Connected" : "Disconnected").foregroundStyle(.secondary)
                    Button(model.terminalConnected ? "Connected" : "Connect") { model.connectTerminal() }
                        .disabled(!model.ready || model.terminalConnected)
                }
                Text("Create an admin: archivebox manage createsuperuser")
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                EmbeddedTerminal(terminal: model.terminal)
                    .frame(maxWidth: .infinity).frame(height: 350)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
                    .accessibilityLabel("Container terminal")
            }
            .padding(24)
        }
        .frame(minWidth: 760, minHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $addingUser) { AddSuperuserView(model: model) }
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
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .monospaced)).monospacedDigit()
        }
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
