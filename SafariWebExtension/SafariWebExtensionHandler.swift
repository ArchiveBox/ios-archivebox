import ArchiveBoxCore
import Foundation
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        do {
            guard let item = context.inputItems.first as? NSExtensionItem,
                  let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any],
                  message["action"] as? String == "get_server_registry",
                  message["schema_version"] as? Int == 1 else {
                throw ArchiveBoxError.message("Unsupported native message.")
            }
            let registry = try AppEnvironment.store.load()
            // Only this bundled extension can call its native handler.
            let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(registry))
            response.userInfo = [SFExtensionMessageKey: ["server_registry": value]]
        } catch {
            response.userInfo = [SFExtensionMessageKey: ["error": error.localizedDescription]]
        }
        context.completeRequest(returningItems: [response])
    }
}
