import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Download through WebKit itself to preserve cookies, POST bodies, and blob URLs.
/// The app-wide owner keeps transfers alive when the user switches sidebar pages.
@MainActor public final class BrowserDownloads: NSObject, WKDownloadDelegate {
    public static let shared = BrowserDownloads()
    private var transfers: [ObjectIdentifier: (download: WKDownload, file: URL?)] = [:]
    #if os(iOS)
    private var exports: [URL] = []
    private var exporting = false
    #endif

    public func track(_ download: WKDownload) {
        transfers[ObjectIdentifier(download)] = (download, nil)
        download.delegate = self
    }

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                         suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        do {
            // Each transfer has a private staging directory: simultaneous downloads
            // cannot collide, and Finder never selects a partially downloaded file.
            let directory = FileManager.default.temporaryDirectory.appending(path: "ArchiveBox-download-\(UUID())", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = (suggestedFilename as NSString).lastPathComponent
            let file = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "Download" : name)
            transfers[ObjectIdentifier(download)] = (download, file)
            completionHandler(file)
        } catch { completionHandler(nil); failed(download, error: error) }
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let transfer = transfers.removeValue(forKey: ObjectIdentifier(download)), let file = transfer.file else { return }
        #if os(macOS)
        do {
            let directory = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let destination = try Self.moveCompletedFile(file, to: directory)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            // This Finder API both selects the completed file and brings its window
            // forward. Do not open the file itself (archives can contain executables).
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { showError(error) }
        #else
        exports.append(file)
        exportNext()
        #endif
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        failed(download, error: error)
    }

    private func failed(_ download: WKDownload, error: Error) {
        if let file = transfers.removeValue(forKey: ObjectIdentifier(download))?.file {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        showError(error)
    }

    // Move only completed downloads and never replace an existing file. The move
    // itself arbitrates races between both apps, not just an existence check.
    public static func moveCompletedFile(_ file: URL, to directory: URL) throws -> URL {
        var number = 1
        while true {
            let suffix = file.pathExtension.isEmpty ? "" : ".\(file.pathExtension)"
            let name = number == 1 ? file.lastPathComponent : "\(file.deletingPathExtension().lastPathComponent) (\(number))\(suffix)"
            let destination = directory.appendingPathComponent(name)
            do { try FileManager.default.moveItem(at: file, to: destination); return destination }
            catch let error as NSError {
                guard error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError else { throw error }
                number += 1
            }
        }
    }

    private func showError(_ error: Error) {
        #if os(macOS)
        let alert = NSAlert(error: error)
        alert.messageText = "Couldn’t save download"
        alert.runModal()
        #else
        guard let presenter = Self.presenter else { return }
        let alert = UIAlertController(title: "Couldn’t save download", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
        #endif
    }

    #if os(iOS)
    private static var presenter: UIViewController? {
        var controller = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
    private func exportNext() {
        guard !exporting, let file = exports.first, let presenter = Self.presenter else { return }
        exporting = true
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.delegate = self
        picker.isModalInPresentation = true
        presenter.present(picker, animated: true)
    }
    #endif
}

#if os(iOS)
extension BrowserDownloads: UIDocumentPickerDelegate {
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { documentPickerWasCancelled(controller) }
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let file = exports.removeFirst()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        controller.dismiss(animated: true) { [self] in exporting = false; exportNext() }
    }
}
#endif
