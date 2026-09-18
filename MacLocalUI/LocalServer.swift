#if os(macOS)
import AppKit
import Foundation
import Observation
import ArchiveBoxCore

@MainActor @Observable
final class LocalServer {
    static let address = ServerAddress.localAPI.absoluteString
    static let releasePage = URL(string: "https://github.com/ArchiveBox/ios-archivebox/releases")!
    var busy = false
    var message = "Runs in the menu bar. Closing the main app does not stop your server."
    var error: String?
    var progress: Double?
    var downloadRequired = false
    private var task: Task<Void, Never>?
    var installedApp: URL? {
        // Launch Services can resolve user-installed apps outside the sandbox's
        // home directory; ignore stale registrations after an app was removed.
        if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.archivebox.Server"),
           FileManager.default.fileExists(atPath: registered.appending(path: "Contents/Info.plist").path) {
            return registered
        }
        return [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/ArchiveBox Server.app"),
         URL(fileURLWithPath: "/Applications/ArchiveBox Server.app")].first {
            FileManager.default.fileExists(atPath: $0.appending(path: "Contents/Info.plist").path)
        }
    }

    func launch(settings: SettingsModel) {
        guard !busy else { return }
        busy = true; error = nil; progress = nil
        task = Task {
            defer { busy = false; task = nil; progress = nil }
            do {
                var app = installedApp
                if app == nil {
                    #if DIRECT_DOWNLOAD
                    app = try await download()
                    #else
                    downloadRequired = true
                    NSWorkspace.shared.open(Self.releasePage)
                    message = "Install ArchiveBox Server in Applications, then choose Run server locally again."
                    return
                    #endif
                }
                guard let app, Bundle(url: app)?.bundleIdentifier == "io.archivebox.Server" else {
                    throw ArchiveBoxError.message("The installed app is not ArchiveBox Server.")
                }
                try Task.checkCancellation()
                message = "Starting ArchiveBox Server…"
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
                let deadline = Date().addingTimeInterval(180)
                var failure = ""
                while Date() < deadline {
                    try Task.checkCancellation()
                    do {
                        let server = try await ArchiveBoxClient().discoverServer(Self.address)
                        guard settings.connectionMode == .local else { return }
                        try await settings.localServerReady(server)
                        message = "Running locally. Use Archive to create your account, then add an API key here for sharing."
                        return
                    } catch is CancellationError { throw CancellationError() }
                    catch { failure = error.localizedDescription }
                    try await Task.sleep(for: .seconds(1))
                }
                throw ArchiveBoxError.message("The local server is not ready. Open ArchiveBox Server’s menu-bar Settings for startup details.\n\(failure)")
            } catch {
                if Task.isCancelled || error is CancellationError {
                    message = "Cancelled. An already launched server keeps running; quit it from its menu-bar menu."
                } else { self.error = error.localizedDescription }
            }
        }
    }

    func cancel() { task?.cancel() }

    #if DIRECT_DOWNLOAD
    // Only the direct-distribution configuration downloads executable companions.
    // App Store builds use the public download page and normal user installation.
    private func download() async throws -> URL {
        message = "Finding ArchiveBox Server download…"
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let releaseURL = URL(string: "https://api.github.com/repos/ArchiveBox/ios-archivebox/releases/latest")!
        let (data, response) = try await session.data(from: releaseURL)
        struct Release: Decodable { struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }; let assets: [Asset] }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              let asset = release.assets.first(where: { $0.name == "ArchiveBox.Server.app.zip" }),
              let digest = asset.digest, digest.hasPrefix("sha256:"),
              digest.dropFirst(7).count == 64,
              digest.dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
            throw ArchiveBoxError.message("No verified ArchiveBox Server release is published yet. Install the companion manually, or try again after a release is available.")
        }
        guard asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com",
              asset.browser_download_url.path.hasPrefix("/ArchiveBox/ios-archivebox/releases/download/") else {
            throw ArchiveBoxError.message("Unexpected companion download location.")
        }
        message = "Downloading ArchiveBox Server…"
        let delegate = ToolsetDownload { [weak self] done, total in
            Task { @MainActor in
                self?.progress = total > 0 ? Double(done) / Double(total) : nil
                self?.message = "Downloading \(ByteCountFormatter.string(fromByteCount: done, countStyle: .file))" +
                    (total > 0 ? " of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))" : "")
            }
        }
        let transfer = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { transfer.invalidateAndCancel() }
        let (temporary, downloadResponse) = try await transfer.download(from: asset.browser_download_url, delegate: delegate)
        guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else { throw ArchiveBoxError.message("The companion download failed.") }
        let fm = FileManager.default
        let applications = fm.homeDirectoryForCurrentUser.appending(path: "Applications")
        try fm.createDirectory(at: applications, withIntermediateDirectories: true)
        let staging = applications.appending(path: ".ArchiveBox-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let zip = staging.appending(path: "server.zip")
        try fm.moveItem(at: temporary, to: zip)
        message = "Verifying and preparing ArchiveBox Server…"; progress = nil
        let hash = try await ProcessCommand.runAsync(URL(fileURLWithPath: "/usr/bin/shasum"), ["-a", "256", zip.path])
        guard hash.status == 0, hash.output.split(whereSeparator: \.isWhitespace).first?.lowercased() == digest.dropFirst(7).lowercased() else { throw ArchiveBoxError.message("The companion download checksum did not match.") }
        let expanded = staging.appending(path: "expanded")
        let extraction = try await ProcessCommand.runAsync(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, expanded.path])
        guard extraction.status == 0 else { throw ArchiveBoxError.message(extraction.output) }
        let app = expanded.appending(path: "ArchiveBox Server.app")
        guard Bundle(url: app)?.bundleIdentifier == "io.archivebox.Server" else { throw ArchiveBoxError.message("The download is not ArchiveBox Server.") }
        let signature = try await ProcessCommand.runAsync(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", "-R=anchor apple generic and certificate leaf[subject.OU] = Q3VA4FKRSA", app.path])
        guard signature.status == 0 else { throw ArchiveBoxError.message("The companion does not have ArchiveBox’s expected signing identity.") }
        let assessment = try await ProcessCommand.runAsync(URL(fileURLWithPath: "/usr/sbin/spctl"), ["--assess", "--type", "execute", app.path])
        guard assessment.status == 0 else { throw ArchiveBoxError.message("macOS did not approve this companion. The release must be signed and notarized.") }
        try Task.checkCancellation()
        let destination = applications.appending(path: "ArchiveBox Server.app")
        // No overwrite/update logic: a running or existing installation stays intact.
        try fm.moveItem(at: app, to: destination)
        return destination
    }
    #endif
}
final class ToolsetDownload: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: @Sendable (Int64, Int64) -> Void
    init(progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
#endif
