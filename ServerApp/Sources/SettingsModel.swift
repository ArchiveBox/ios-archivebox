import AppKit
import SwiftUI
import SwiftTerm
import ArchiveBoxCore

@MainActor
final class SettingsModel: ObservableObject {
    @Published var collectionDirectory: URL
    @Published var changingCollection = false
    @Published var collectionError: String?
    @Published var profileImportMessage = ""
    @Published var profileImportError: String?
    @Published var importingProfiles = false
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
    @Published var startupLog = ""
    @Published var ready = false
    @Published var terminalConnected = false
    @Published var networkOptions = NetworkOptions.load()
    @Published var networkURLs: [URL] = []
    @Published private var connectionAPIKey: String?
    var qrAPIKey: String? { ready && hasAdmin && !changingCollection ? connectionAPIKey : nil }
    private lazy var networkAccess = NetworkAccess(runtime: runtime)
    private let bonjour = ArchiveBoxBonjour()
    @Published var serverDetails: ServerDetails? {
        didSet { advertiseNetwork() }
    }
    private var sharingTask: Task<Void, Never>?
    @Published var sharingPublic = false
    @Published var sharingBusy = false
    @Published var sharingMessage: String?
    @Published var sharingError: String?
    @Published var tailscaleApprovalURL: URL?
    @Published var managementBusy = false
    @Published var managementError: String?
    @Published var tailscaleURL: URL?
    @Published var tailscaleIP: String?
    var tailscaleConnectionURL: URL? {
        guard let tailscaleIP else { return nil }
        let applied = NetworkOptions.load()
        if applied.https, let url = networkURLs.first(where: { $0.scheme == "https" }) { return url }
        return networkURLs.first(where: { $0.host() == tailscaleIP })
            ?? URL(string: "http://\(tailscaleIP):\(applied.port)")
    }
    var primaryConnectionURL: URL? {
        if let details = serverDetails, !(details.configuredBaseURL ?? "").isEmpty { return details.base }
        return networkURLs.first(where: { $0.scheme == "https" }) ?? networkURLs.first ?? serverDetails?.base
    }
    @Published var tailscaleError: String?
    @Published var baseURLDraft = ""
    @Published var securityModeDraft = "auto"
    @Published var restarting = false
    @Published var httpMessage: String?
    @Published var httpError: String?
    var httpChanged: Bool { baseURLDraft != (serverDetails?.configuredBaseURL ?? serverDetails?.base.absoluteString) || securityModeDraft != serverDetails?.securityMode }
    var hasAdmin: Bool { serverDetails?.hasAdmin == true }
    var didUpdateDetails: ((ServerDetails) async throws -> Void)?
    @Published var connectionError: String?
    @Published var connecting = false
    var healthy: Bool { ready && !starting && !restarting && connectionError == nil }
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
    var starting: Bool { !startupFinished || connecting }
    private var startupError: String?
    private var lastSizeRefresh = Date.distantPast
    var terminalDelegate: TerminalDelegate!

    func refreshStartupLog() async {
        let log = runtime.home.appendingPathComponent("desktop.log")
        startupLog = await Task.detached {
            guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
            defer { try? handle.close() }
            do {
                let size = try handle.seekToEnd()
                let offset = size > 16_384 ? size - 16_384 : 0
                try handle.seek(toOffset: offset)
                let data = try handle.readToEnd() ?? Data()
                var lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                if offset > 0, !lines.isEmpty { lines.removeFirst() }
                return lines.suffix(5).joined(separator: "\n")
            } catch { return "Could not read startup log: \(error.localizedDescription)" }
        }.value
    }

    init(runtime: Runtime) {
        self.runtime = runtime
        collectionDirectory = runtime.collectionDirectory
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeForegroundColor = .textColor
        terminal.nativeBackgroundColor = .textBackgroundColor
        terminalDelegate = TerminalDelegate(model: self)
        terminal.processDelegate = terminalDelegate
    }

    func finishStartup() async throws {
        detail = "Loading server configuration…"
        await refreshTailscale()
        let details = try await Task.detached { [runtime] in try runtime.management() }.value
        if UserDefaults.standard.data(forKey: "networkAccessOptions") != nil {
            networkURLs = try await networkAccess.start(options: networkOptions)
        }
        serverDetails = details
        baseURLDraft = details.configuredBaseURL ?? details.base.absoluteString
        securityModeDraft = details.securityMode
        detail = details.hasAdmin ? "Signing in to the server…" : "Preparing first-time setup…"
        try await didUpdateDetails?(details)
        connectionAPIKey = details.hasAdmin ? try await Task.detached { [runtime] in try runtime.browserAPIKey() }.value : nil
        didStart()
        automaticallyConnectTailnetIfNeeded()
        importBrowserProfiles()
    }

    func importBrowserProfiles() {
        guard ready, !importingProfiles, !shuttingDown else { return }
        importingProfiles = true
        profileImportError = nil
        profileImportMessage = "Checking browser profiles…"
        Task {
            defer { importingProfiles = false }
            do {
                try await Task.detached { [runtime] in
                    try runtime.seedBrowserPersonas { message in
                        Task { @MainActor in self.profileImportMessage = message }
                    }
                }.value
                profileImportMessage = "Browser profiles imported. Existing and deleted Personas are left unchanged."
            } catch {
                profileImportMessage = ""
                profileImportError = error.localizedDescription
                let log = runtime.home.appendingPathComponent("desktop.log")
                if let handle = try? FileHandle(forWritingTo: log) {
                    handle.seekToEndOfFile()
                    handle.write(Data(("\nBrowser profile import: " + error.localizedDescription + "\n").utf8))
                    try? handle.close()
                }
            }
        }
    }

    func didStart(error: String? = nil) {
        startupFinished = true
        startupError = error
        connectionError = error
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
        ready = sample.state == "running" && startupError == nil
        if ready {
            state = connectionError == nil ? "Running" : "Connection failed"
            detail = connectionError ?? sample.error ?? ""
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
        guard ready, loadingDetails == nil, !managementBusy, !sharingBusy, !restarting else { return }
        loadingDetails = Task {
            _ = await updateUsers()
            await refreshTailscale()
            loadingDetails = nil
        }
    }

    private func refreshTailscale() async {
        do {
            let status = try await TailscaleNetwork.read()
            tailscaleIP = status.Self?.TailscaleIPs?.first(where: { !$0.contains(":") })
            tailscaleURL = tailscaleConnectionURL
            tailscaleError = nil
        } catch {
            tailscaleIP = nil; tailscaleURL = nil
            tailscaleError = error.localizedDescription
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
                baseURLDraft = serverDetails.configuredBaseURL ?? serverDetails.base.absoluteString; securityModeDraft = serverDetails.securityMode
            }
            if let serverDetails {
                connecting = true
                defer { connecting = false }
                try await didUpdateDetails?(serverDetails)
                connectionAPIKey = serverDetails.hasAdmin ? try await Task.detached { [runtime] in try runtime.browserAPIKey() }.value : nil
            }
            connectionError = nil
            return true
        } catch {
            connectionError = error.localizedDescription
            state = "Connection failed"
            managementError = error.localizedDescription
            return false
        }
    }

    func restartContainer(savingHTTPSettings: Bool = false) {
        guard runtime.ownsService, !starting, !managementBusy, !restarting, !shuttingDown,
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
                    baseURLDraft = updated.configuredBaseURL ?? updated.base.absoluteString; securityModeDraft = updated.securityMode
                }
                try await didUpdateDetails?(updated)
                startupError = nil
                expectedRunning = true
                connectionError = nil
                ready = true; state = "Running"
                httpMessage = savingHTTPSettings ? "Settings saved. Container restarted." : "Container restarted."
            } catch {
                connectionError = error.localizedDescription
                state = "Connection failed"
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
                importBrowserProfiles()
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

extension SettingsModel {
    private func automaticallyConnectTailnetIfNeeded() {
        guard hasAdmin, serverDetails?.base.host()?.hasSuffix(".localhost") == true,
              UserDefaults.standard.string(forKey: "networkSetupChoice") == nil,
              TailscaleNetwork.executable != nil else { return }
        startSharing()
    }
    enum SharingMode { case direct, serve, funnel }
    func startSharing(mode: SharingMode = .direct) {
        guard sharingTask == nil else { return }
        UserDefaults.standard.set(String(describing: mode), forKey: "networkSetupChoice")
        sharingTask = Task { await enableSharing(mode: mode); sharingTask = nil }
    }
    func finishPrivateSharing() async { await sharingTask?.value }

    /// Configure only an unused HTTPS listener; never replace another app's proxy or Funnel.
    func enableSharing(mode: SharingMode) async {
        if mode == .direct { await enableDirectSharing(); return }
        let publicAccess = mode == .funnel
        guard ready, hasAdmin, runtime.ownsService, !managementBusy, !restarting, !starting,
              !sharingBusy, !httpChanged, let previous = serverDetails else { return }
        sharingBusy = true; sharingMessage = "Checking Tailscale…"; sharingError = nil; tailscaleApprovalURL = nil
        defer { sharingBusy = false; if !shuttingDown { monitor() } }
        pauseMonitoring()
        await loadingDetails?.value
        var changedListener: (port: Int, previousPublic: Bool?)?
        var settingsChanged = false
        var executable: URL?
        do {
            let network = try await TailscaleNetwork.read()
            guard let name = network.Self?.hostname, let cli = TailscaleNetwork.executable else {
                throw ArchiveBoxError.message("Open Tailscale and connect this Mac, then try again.")
            }
            executable = cli
            let existing = try await ProcessCommand.runAsync(cli, ["serve", "status", "--json"], timeout: 8)
            guard existing.status == 0, let config = try JSONSerialization.jsonObject(with: Data(existing.output.utf8)) as? [String: Any] else {
                throw ArchiveBoxError.message("Could not check existing Tailscale sharing. No settings were changed.")
            }
            let tcp = config["TCP"] as? [String: Any] ?? [:]
            let web = config["Web"] as? [String: [String: Any]] ?? [:]
            let funnel = config["AllowFunnel"] as? [String: Bool] ?? [:]
            let backend = "http://127.0.0.1:18080"
            let reusable = [443, 8443].first { port in
                let key = "\(name):\(port)"
                let handlers = web[key]?["Handlers"] as? [String: [String: String]]
                return handlers?.count == 1 && handlers?["/"]?["Proxy"] == backend
            }
            guard let port = reusable ?? [443, 8443].first(where: { tcp[String($0)] == nil && funnel["\(name):\($0)"] != true }) else {
                throw ArchiveBoxError.message("Tailscale ports 443 and 8443 already serve other apps. Use the advanced guide to choose another port; existing services were kept.")
            }
            let address = URL(string: "https://\(name)\(port == 443 ? "" : ":\(port)")")!
            let previousPublic = reusable.map { funnel["\(name):\($0)"] == true }
            if previousPublic != publicAccess {
                // Record before invoking the CLI: a timeout can happen after it changes config.
                changedListener = (port, previousPublic)
                sharingMessage = publicAccess ? "Creating a public HTTPS address…" : "Creating a private HTTPS address…"
                let result = try await ProcessCommand.runAsync(cli, [publicAccess ? "funnel" : "serve", "--yes", "--bg", "--https=\(port)", backend], timeout: 25) { [weak self] output in
                    // Tailscale can require the owner to enable HTTPS in their browser.
                    let urls = output.split(whereSeparator: \.isWhitespace).compactMap { URL(string: String($0)) }
                    if let link = urls.first(where: { $0.scheme == "https" && $0.host() == "login.tailscale.com" }) {
                        Task { @MainActor [weak self] in self?.tailscaleApprovalURL = link }
                    }
                }
                guard result.status == 0 else { throw ArchiveBoxError.message("Tailscale could not enable sharing. Open its approval link if shown, then try again.") }

            }
            sharingMessage = "Saving the address and restarting ArchiveBox…"
            restarting = true
            let updated: ServerDetails
            if (previous.configuredBaseURL ?? previous.base.absoluteString) == networkOptions.baseURL, previous.securityMode == networkOptions.effectiveSecurityMode {
                updated = previous
            } else {
                settingsChanged = true
                let options = networkOptions
                updated = try await Task.detached { [runtime] in
                    try await runtime.applyHTTPSettings(baseURL: options.baseURL, securityMode: options.effectiveSecurityMode)
                }.value
            }
            sharingMessage = "Verifying the HTTPS address and ArchiveBox API…"
            _ = try await ArchiveBoxClient().discoverServer(address.absoluteString)
            let check = try await ProcessCommand.runAsync(cli, ["serve", "status", "--json"], timeout: 8)
            let checked = try JSONSerialization.jsonObject(with: Data(check.output.utf8)) as? [String: Any]
            let publicListeners = checked?["AllowFunnel"] as? [String: Bool] ?? [:]
            guard check.status == 0, (publicListeners["\(name):\(port)"] == true) == publicAccess else {
                throw ArchiveBoxError.message("Tailscale’s access setting did not match the requested mode.")
            }
            try await didUpdateDetails?(updated)
            UserDefaults.standard.set(port, forKey: "archiveboxManagedTailscaleHTTPSPort")
            sharingPublic = publicAccess
            if !networkURLs.contains(address) { networkURLs.append(address) }
            serverDetails = updated; baseURLDraft = updated.configuredBaseURL ?? updated.base.absoluteString; securityModeDraft = updated.securityMode
            tailscaleURL = address; connectionError = nil; ready = true; state = "Running"
            sharingMessage = publicAccess
                ? "Funnel is enabled and the HTTPS API works from this Mac. Check from a phone with Wi-Fi and Tailscale off to confirm access from outside your network."
                : "Ready. On your iPhone, open ArchiveBox → Find a server. Keep Tailscale connected."
            restarting = false
        } catch {
            let problem = error.localizedDescription
            var recovery = ""
            if settingsChanged {
                do {
                    let restored = try await Task.detached { [runtime] in
                        try await runtime.applyHTTPSettings(baseURL: previous.configuredBaseURL ?? previous.base.absoluteString, securityMode: previous.securityMode)
                    }.value
                    try await didUpdateDetails?(restored)
                    serverDetails = restored; baseURLDraft = restored.configuredBaseURL ?? restored.base.absoluteString; securityModeDraft = restored.securityMode
                    recovery = " Previous ArchiveBox settings restored."
                } catch { recovery = " Could not restore the previous address: \(error.localizedDescription). Check HTTP, TLS, and DNS settings." }
            }
            if let changedListener, let executable {
                do {
                    let args: [String]
                    if let wasPublic = changedListener.previousPublic {
                        args = [wasPublic ? "funnel" : "serve", "--yes", "--bg", "--https=\(changedListener.port)", "http://127.0.0.1:18080"]
                    } else { args = [publicAccess ? "funnel" : "serve", "--https=\(changedListener.port)", "off"] }
                    let result = try await ProcessCommand.runAsync(executable, args, timeout: 8)
                    if result.status != 0 { recovery += " Could not restore the Tailscale listener on \(changedListener.port)." }
                } catch { recovery += " Could not restore the Tailscale listener on \(changedListener.port)." }
            }
            restarting = false; sharingMessage = nil; sharingError = problem + recovery
        }
    }
}


extension SettingsModel {
    private func enableDirectSharing() async {
        await applyNetworkOptions()
    }
    func advertiseNetwork() {
        if !networkURLs.isEmpty { bonjour.publish(networkURLs) }
        else if let base = serverDetails?.base { bonjour.publish(base) }
    }
    func stopNetworkAccess() async { await networkAccess.stop(); bonjour.publish([]) }

    func applyNetworkOptions() async {
        guard ready, hasAdmin, runtime.ownsService, !managementBusy, !restarting, !starting,
              !sharingBusy, let previous = serverDetails else { return }
        let options = networkOptions
        let oldOptions = NetworkOptions.load()
        let hadNetworkOptions = UserDefaults.standard.data(forKey: "networkAccessOptions") != nil
        sharingBusy = true; sharingMessage = "Preparing network access…"; sharingError = nil
        pauseMonitoring(); await loadingDetails?.value
        defer { sharingBusy = false; restarting = false; if !shuttingDown { monitor() } }
        var changed = false
        do {
            if options.internet && (!options.https || options.certificate != .tailscale) {
                throw ArchiveBoxError.message("For automatic internet access choose HTTPS with Tailscale Serve / Funnel. Other providers need their domain, certificate and public routing configured in certificate setup first.")
            }
            if options.https && options.certificate != .tailscale && options.certificate != .own {
                throw ArchiveBoxError.message("Complete certificate setup, then select My own certificate to import the certificate and key, or use an existing HTTPS proxy address.")
            }
            if options.https && options.certificate == .tailscale && !options.tailnet && !options.internet {
                throw ArchiveBoxError.message("Enable Tailscale network access to use private Serve HTTPS, or choose a certificate for your LAN hostname.")
            }
            if options.https && options.certificate == .own && options.baseURL.isEmpty {
                throw ArchiveBoxError.message("Enter the HTTPS hostname covered by your certificate as BASE_URL.")
            }
            networkURLs = try await networkAccess.start(options: options)
            restarting = true; sharingMessage = "Applying ArchiveBox’s address and security mode…"
            let updated: ServerDetails
            if (previous.configuredBaseURL ?? previous.base.absoluteString) == options.baseURL && previous.securityMode == options.effectiveSecurityMode { updated = previous }
            else {
                changed = true
                updated = try await Task.detached { [runtime] in
                    try await runtime.applyHTTPSettings(baseURL: options.baseURL, securityMode: options.effectiveSecurityMode)
                }.value
            }
            let checkURLs = options.baseURL.isEmpty ? networkURLs : [try ServerAddress.normalize(options.baseURL)]
            for url in checkURLs { _ = try await ArchiveBoxClient().discoverServer(url.absoluteString) }
            try await didUpdateDetails?(updated)
            serverDetails = updated; baseURLDraft = updated.configuredBaseURL ?? updated.base.absoluteString; securityModeDraft = updated.securityMode
            ready = true; state = "Running"; connectionError = nil
            advertiseNetwork()
            sharingMessage = "Network addresses verified. On your iPhone, scan a connection code or choose Find a server."
            if options.https && options.certificate == .tailscale {
                sharingBusy = false; restarting = false
                await enableSharing(mode: options.internet ? .funnel : .serve)
                if let error = sharingError { throw ArchiveBoxError.message(error) }
            } else {
                try await removeManagedTailscaleHTTPS()
            }
            options.save()
        } catch {
            var message = error.localizedDescription
            if changed {
                do {
                    let restored = try await Task.detached { [runtime] in
                        try await runtime.applyHTTPSettings(baseURL: previous.configuredBaseURL ?? previous.base.absoluteString, securityMode: previous.securityMode)
                    }.value
                    try await didUpdateDetails?(restored)
                    serverDetails = restored; baseURLDraft = restored.configuredBaseURL ?? restored.base.absoluteString; securityModeDraft = restored.securityMode
                    message += " Previous server settings restored."
                } catch { message += " Could not restore server settings: \(error.localizedDescription)" }
            }
            do {
                if hadNetworkOptions { networkURLs = try await networkAccess.start(options: oldOptions) }
                else { await networkAccess.stop(); networkURLs = [] }
            }
            catch { await networkAccess.stop(); networkURLs = []; message += " Previous network listeners could not restart." }
            advertiseNetwork(); sharingMessage = nil; sharingError = message
        }
    }

    private func removeManagedTailscaleHTTPS() async throws {
        let port = UserDefaults.standard.integer(forKey: "archiveboxManagedTailscaleHTTPSPort")
        guard port != 0 else { return }
        guard let cli = TailscaleNetwork.executable else { throw ArchiveBoxError.message("Open Tailscale to turn off the previous HTTPS listener.") }
        let status = try await ProcessCommand.runAsync(cli, ["serve", "status", "--json"], timeout: 8)
        guard status.status == 0 else { throw ArchiveBoxError.message("Could not check the previous Tailscale HTTPS listener.") }
        let config = try JSONSerialization.jsonObject(with: Data(status.output.utf8)) as? [String: Any] ?? [:]
        let web = config["Web"] as? [String: [String: Any]] ?? [:]
        let entries = web.filter { $0.key.hasSuffix(":\(port)") }
        if !entries.isEmpty {
            guard entries.values.allSatisfy({ entry in
                let handlers = entry["Handlers"] as? [String: [String: String]]
                return handlers?.count == 1 && handlers?["/"]?["Proxy"] == "http://127.0.0.1:18080"
            }) else { throw ArchiveBoxError.message("The previous Tailscale listener now serves another app. Review it in Tailscale before changing access here.") }
            let disabled = try await ProcessCommand.runAsync(cli, ["serve", "--https=\(port)", "off"], timeout: 8)
            guard disabled.status == 0 else { throw ArchiveBoxError.message("Could not turn off the previous Tailscale HTTPS listener.") }
            let check = try await ProcessCommand.runAsync(cli, ["serve", "status", "--json"], timeout: 8)
            let remaining = try JSONSerialization.jsonObject(with: Data(check.output.utf8)) as? [String: Any]
            let tcp = remaining?["TCP"] as? [String: Any] ?? [:]
            guard check.status == 0, tcp[String(port)] == nil else { throw ArchiveBoxError.message("The previous Tailscale HTTPS listener is still active.") }
        }
        UserDefaults.standard.removeObject(forKey: "archiveboxManagedTailscaleHTTPSPort")
        sharingPublic = false
    }
}
