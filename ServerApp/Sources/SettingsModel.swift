import AppKit
import SwiftUI
import SwiftTerm
import ArchiveBoxCore

@MainActor
final class SettingsModel: ObservableObject {
    @Published var collectionDirectory: URL
    @Published var changingCollection = false
    @Published var collectionError: String?
    var showCollectionShell: (() async -> Void)?
    var terminalCompletion: CheckedContinuation<Int32?, Never>?
    private var changingCollectionTask: Task<Void, Never>?
    private var shuttingDown = false
    @Published var state = "Starting"
    @Published var cpu = "—"
    @Published var ram = "—"
    @Published var memory = MemoryBreakdown()
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
    @Published var baseURLDraft = ""
    @Published var securityModeDraft = "auto"
    @Published var restarting = false
    @Published var httpMessage: String?
    @Published var httpError: String?
    var httpChanged: Bool { baseURLDraft != serverDetails?.base.absoluteString || securityModeDraft != serverDetails?.securityMode }
    var hasAdmin: Bool { serverDetails?.hasAdmin == true }
    var didUpdateDetails: ((ServerDetails) async -> Void)?
    var openAdmin: ((URL) -> Void)?
    let runtime: Runtime
    let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 350))
    private var polling: Task<Void, Never>?
    private var sizing: Task<Void, Never>?
    private var loadingDetails: Task<Void, Never>?
    private var applyingHTTP: Task<Void, Never>?
    private var previous: ContainerSample?
    private var expectedRunning = false
    private var startupFinished = false
    private var startupError: String?
    private var lastSizeRefresh = Date.distantPast
    var terminalDelegate: TerminalDelegate!

    init(runtime: Runtime) {
        self.runtime = runtime
        collectionDirectory = runtime.collectionDirectory
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
                    // Only the Settings screen requests this extra lightweight read;
                    // toolbar/menu summaries keep using the existing container total.
                    let breakdown = await Task.detached { [runtime] in runtime.memoryBreakdown() }.value
                    if Task.isCancelled { return }
                    memory = breakdown
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func pauseMonitoring() { polling?.cancel(); polling = nil; previous = nil }

    func apply(_ sample: ContainerSample) {
        guard !restarting else { return }
        ready = sample.state == "running"
        if ready {
            state = "Running"
            detail = sample.error ?? ""
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
            cpu = String(format: "%.0f%%", (now - old) / 1_000_000 / (sample.time - before.time) * 100)
        }
        ram = sample.memory.map { String(format: "%.0f MB", Double($0) / 1_048_576) } ?? "—"
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
        guard ready, !managementBusy, !restarting else { return false }
        managementBusy = true; managementError = nil
        defer { managementBusy = false }
        do {
            let refreshDraft = serverDetails == nil || !httpChanged
            serverDetails = try await Task.detached { [runtime] in
                try runtime.management(username: username, email: email, password: password)
            }.value
            if refreshDraft, let serverDetails {
                baseURLDraft = serverDetails.base.absoluteString; securityModeDraft = serverDetails.securityMode
            }
            if let serverDetails { await didUpdateDetails?(serverDetails) }
            return true
        } catch {
            managementError = error.localizedDescription
            return false
        }
    }

    func restartContainer(savingHTTPSettings: Bool = false) {
        guard ready, !managementBusy, !restarting, !shuttingDown,
              !savingHTTPSettings || httpChanged else { return }
        restarting = true; httpError = nil
        httpMessage = savingHTTPSettings ? "Saving settings and restarting the container…" : "Restarting the container…"
        pauseMonitoring()
        let base = baseURLDraft, mode = securityModeDraft
        applyingHTTP = Task {
            defer { restarting = false; applyingHTTP = nil; monitor() }
            do {
                let updated = try await Task.detached { [runtime] in
                    if savingHTTPSettings {
                        return try await runtime.applyHTTPSettings(baseURL: base, securityMode: mode)
                    }
                    return try await runtime.restartContainer()
                }.value
                serverDetails = updated
                // A plain restart must not apply or discard unfinished HTTP edits.
                if savingHTTPSettings {
                    baseURLDraft = updated.base.absoluteString; securityModeDraft = updated.securityMode
                }
                ready = true; state = "Running"
                await didUpdateDetails?(updated)
                httpMessage = savingHTTPSettings ? "Settings saved. Container restarted." : "Container restarted."
            } catch {
                httpMessage = nil; httpError = error.localizedDescription
            }
        }
    }

    func finishHTTPChange() async { await applyingHTTP?.value }

    func chooseCollection() {
        guard runtime.ownsService, !managementBusy, !restarting, changingCollectionTask == nil else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false; picker.directoryURL = collectionDirectory
        picker.prompt = "Use this folder"
        guard picker.runModal() == .OK, let directory = picker.url else { return }
        restarting = true; changingCollection = true; collectionError = nil
        pauseMonitoring()
        changingCollectionTask = Task {
            defer { changingCollection = false; restarting = false; changingCollectionTask = nil }
            await loadingDetails?.value
            await sizing?.value
            guard !shuttingDown else { return }
            do {
                try await Task.detached { [runtime] in try runtime.prepareCollection(directory) }.value
                guard !shuttingDown else { return }
                // Stopping the container ends its shell. Drain that exit before
                // attaching init: SwiftTerm.terminate() cancels the exit monitor,
                // and signalling the CLI alone can leave interactive Bash running.
                if terminalConnected, terminal.process.shellPid > 0 {
                    _ = await withCheckedContinuation { terminalCompletion = $0 }
                }
                collectionDirectory = runtime.collectionDirectory
                ready = false; state = "Initializing collection"; serverDetails = nil
                disk = "Calculating…"; baseURLDraft = ""; securityModeDraft = "auto"; tailscaleURL = nil
                await showCollectionShell?()
                guard !shuttingDown else { return }
                terminalConnected = true
                let status = await withCheckedContinuation { terminalCompletion = $0
                    terminal.startProcess(executable: runtime.cli.path, args: runtime.initializeCollectionArguments,
                        environment: ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" })
                }
                guard !shuttingDown else { return }
                guard status == 0 else { throw ArchiveBoxError.message("archivebox init exited with status \(status.map(String.init) ?? "unknown"). Choose the folder again to retry; see Shell for details.") }
                state = "Starting server"
                try await Task.detached { [runtime] in try await runtime.startCollection() }.value
                ready = true; state = "Running"; restarting = false
                _ = await updateUsers()
                refreshSize()
                connectTerminal(focus: false)
            } catch {
                restarting = false
                let sample = await Task.detached { [runtime] in runtime.sample() }.value
                apply(sample)
                if !ready { state = "Collection setup failed" }
                collectionError = error.localizedDescription
                terminal.feed(text: "\r\n\(error.localizedDescription)\r\n")
            }
        }
    }

    func finishCollectionChange() async { await changingCollectionTask?.value }

    func connectTerminal(focus: Bool = true) {
        guard ready, !restarting, !terminalConnected else { return }
        terminalConnected = true
        // The existing image entrypoint selects its writable unprivileged user and
        // environment. A PTY on both sides preserves password prompts and signals.
        terminal.startProcess(executable: runtime.cli.path,
            args: ["exec", "--interactive", "--tty", "--env", "TERM=xterm-256color",
                   "--workdir", "/data", runtime.name, "/app/bin/docker_entrypoint.sh",
                   // Run help before replacing this process with the interactive
                   // shell, so startup output cannot race PTY input or get lost.
                   "/bin/bash", "--noprofile", "--norc", "-c",
                   "printf '$ archivebox help\\n'; archivebox help; exec /bin/bash --noprofile --norc -i"],
            environment: ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" })
        if focus { terminal.window?.makeFirstResponder(terminal) }
    }

    func shutdown() {
        shuttingDown = true; pauseMonitoring(); sizing?.cancel()
        terminalCompletion?.resume(returning: nil); terminalCompletion = nil
        terminal.terminate()
    }
}

@MainActor final class TerminalDelegate: LocalProcessTerminalViewDelegate {
    weak var model: SettingsModel?
    init(model: SettingsModel) { self.model = model }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            guard let model = self?.model else { return }
            model.terminalConnected = false
            if let completion = model.terminalCompletion {
                model.terminalCompletion = nil; completion.resume(returning: exitCode); return
            }
            model.terminal.feed(text: "\r\n[Shell exited\(exitCode.map { " (status \($0))" } ?? ""). Click Connect to open a new shell.]\r\n")
        }
    }
}

struct EmbeddedTerminal: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    func makeNSView(context: Context) -> LocalProcessTerminalView { terminal }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

