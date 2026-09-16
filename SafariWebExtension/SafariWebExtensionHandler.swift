import ArchiveBoxCore
import Foundation
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        do {
            guard let item = context.inputItems.first as? NSExtensionItem,
                  let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any],
                  message["action"] as? String == "getConnection" else {
                throw ArchiveBoxError.message("Unsupported native message.")
            }
            guard let configuration = try AppEnvironment.store.load() else {
                throw ArchiveBoxError.message("Test and save a connection in the ArchiveBox app first.")
            }
            // Only this bundled extension can call its native handler. Import is user-initiated;
            // web content cannot read Keychain or invoke sendNativeMessage directly.
            response.userInfo = [SFExtensionMessageKey: ["connection": [
                "server": configuration.server.absoluteString,
                "token": configuration.token,
            ]]]
        } catch {
            response.userInfo = [SFExtensionMessageKey: ["error": error.localizedDescription]]
        }
        context.completeRequest(returningItems: [response])
    }
}
