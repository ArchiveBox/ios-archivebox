import AppKit
import ArchiveBoxCore
import WebKit

// Sign in through the real admin form, then verify the app's normal SettingsModel
// saves that user's key. Restore the registry and remove only this temporary user.
@main struct ClientWebLoginAcceptance {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }

    @MainActor static func run() async throws {
        _ = NSApplication.shared
        let runtime = Runtime(resources: URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: "Contents/Resources"))
        let original = try AppEnvironment.store.load()
        let originalTags = try Dictionary(uniqueKeysWithValues: original.servers.map { ($0.id, try AppEnvironment.store.recentTags(serverID: $0.id)) })
        let setupDismissed = UserDefaults.standard.object(forKey: "setupGuideDismissed")
        let username = "web-login-acceptance-" + UUID().uuidString.lowercased()
        let password = UUID().uuidString + UUID().uuidString
        let setup = """
        import json,sys
        from django.contrib.auth import get_user_model
        data=json.load(sys.stdin)
        user=get_user_model().objects.create_superuser(username=data['username'],email='acceptance@example.invalid',password=data['password'])
        print('ACCEPTANCE_USER='+str(user.pk))
        """
        let output = try runtime.command(["exec", "--interactive", runtime.name, "/app/bin/docker_entrypoint.sh", "archivebox", "manage", "shell", "-c", setup],
            logOutput: false, input: JSONSerialization.data(withJSONObject: ["username": username, "password": password]))
        guard let line = output.components(separatedBy: .newlines).first(where: { $0.hasPrefix("ACCEPTANCE_USER=") }),
              let userID = Int(line.dropFirst("ACCEPTANCE_USER=".count)) else { throw ArchiveBoxError.message("Temporary administrator was not created.") }
        let details = (api: ServerAddress.localAPI, base: ServerAddress.localServer,
                       admin: URL(string: "http://admin.archivebox.localhost:5797/admin/")!)
        defer {
            do {
                try AppEnvironment.store.save(original)
                for (id, tags) in originalTags { _ = try AppEnvironment.store.recentTags(serverID: id, adding: Array(tags.reversed())) }
                UserDefaults.standard.set(setupDismissed, forKey: "setupGuideDismissed")
                ArchiveSystemIndex.connectionChanged()
                let cleanup = """
                import json,sys
                from django.contrib.auth import get_user_model
                from django.contrib.sessions.models import Session
                data=json.load(sys.stdin)
                for session in Session.objects.all():
                    if session.get_decoded().get('_auth_user_id') == str(data['id']): session.delete()
                get_user_model().objects.filter(pk=data['id'], username=data['username']).delete()
                """
                _ = try runtime.command(["exec", "--interactive", runtime.name, "/app/bin/docker_entrypoint.sh", "archivebox", "manage", "shell", "-c", cleanup],
                    logOutput: false, input: JSONSerialization.data(withJSONObject: ["id": userID, "username": username]))
            } catch { fatalError("Could not restore web-login acceptance state: \(error.localizedDescription)") }
        }
        let settings = SettingsModel()
        settings.serverText = details.api.absoluteString
        await settings.testServer()
        guard let server = settings.verifiedServer else { throw ArchiveBoxError.message("Server discovery failed.") }
        let pages = WebPages()
        pages.onWebLogin = { [weak settings, weak authentication = pages.authentication] page in
            guard let settings, let authentication else { return }
            settings.useWebLogin(page, authentication: authentication)
        }
        let page = pages.page(for: "admin", baseURL: details.base, server: server, token: nil)
        page.load(details.admin.appending(path: "api/apitoken/"), requestID: nil)
        try await wait {
            guard !page.page.isLoading else { return false }
            return (try? await page.page.evaluateJavaScript("document.querySelector('input[name=password]') !== null")) as? Bool == true
        }
        guard try await pages.authentication.apiKey(from: page.page, server: server) == nil,
              settings.tokenText.isEmpty, settings.verifiedToken == nil else {
            throw ArchiveBoxError.message("An unauthenticated page supplied a key.")
        }
        _ = try await page.page.callAsyncJavaScript("""
            document.querySelector('input[name=username]').value = username;
            document.querySelector('input[name=password]').value = password;
            document.querySelector('input[name=password]').form.requestSubmit();
            """, arguments: ["username": username, "password": password], in: nil, contentWorld: .page)
        try await wait { !settings.busy && settings.verifiedToken != nil }
        guard let token = settings.verifiedToken, settings.errorMessage == nil,
              let saved = try AppEnvironment.store.load().active_server,
              saved.server == server, saved.token == token, settings.tokenText == token else {
            throw ArchiveBoxError.message("Web sign-in did not persist the verified key in Connection Settings.")
        }
        let ownership = """
        import json,sys
        from archivebox.api.models import APIToken
        data=json.load(sys.stdin)
        token=APIToken.objects.get(token=data['token'])
        assert token.created_by_id == data['id']
        assert APIToken.objects.filter(created_by_id=data['id']).count() == 1
        print('OWNER_OK')
        """
        let result = try runtime.command(["exec", "--interactive", runtime.name, "/app/bin/docker_entrypoint.sh", "archivebox", "manage", "shell", "-c", ownership],
            logOutput: false, input: JSONSerialization.data(withJSONObject: ["id": userID, "token": token]))
        guard result.contains("OWNER_OK") else { throw ArchiveBoxError.message("Key belongs to a different account.") }
        guard try await pages.authentication.apiKey(from: page.page, server: URL(string: "https://unrelated.example")!) == nil else {
            throw ArchiveBoxError.message("A different configured server accepted the page's key.")
        }
        settings.tokenChanged()
        settings.tokenText = "existing-manual-input"
        settings.useWebLogin(page.page, authentication: pages.authentication)
        guard settings.tokenText == "existing-manual-input", !settings.busy else {
            throw ArchiveBoxError.message("Web sign-in overwrote an existing key field.")
        }
        // Exercise four real reachable origins, including key rejection, through
        // the same actions used by Connection Settings. No seeded history rows.
        let origins = [details.api, details.base, URL(string: "http://127.0.0.1:5797")!, URL(string: "http://localhost:5797")!]
        var idsByOrigin: [URL: String] = [:]
        for origin in origins {
            settings.useConnectionLink(origin, apiKey: token)
            try await wait { !settings.busy && settings.verifiedToken == token && settings.verifiedServer == origin }
            guard let saved = try AppEnvironment.store.load().servers.first(where: { $0.server == origin }) else {
                throw ArchiveBoxError.message("A configured destination was not persisted: \(origin.absoluteString)")
            }
            idsByOrigin[origin] = saved.id
        }
        let recent = settings.rememberedServers
        guard settings.quickSwitchServers == recent else { throw ArchiveBoxError.message("Verified connections missing from quick switching.") }
        let registryAfterOrigins = try AppEnvironment.store.load()
        let expectedOrigins = Set(original.servers.map(\.server)).union(origins)
        let firstOrigin = registryAfterOrigins.servers.first { $0.server == origins[0] }
        guard let latestOrigin = registryAfterOrigins.servers.first(where: { $0.server == origins[3] }) else {
            throw ArchiveBoxError.message("The latest configured destination was not retained.")
        }
        guard recent.map(\.server) == Array(origins.reversed().prefix(3)),
              registryAfterOrigins.servers.count == expectedOrigins.count,
              Set(registryAfterOrigins.servers.map(\.server)) == expectedOrigins,
              firstOrigin?.id == idsByOrigin[origins[0]],
              firstOrigin?.token == token, firstOrigin?.persona == nil,
              registryAfterOrigins.default_server_ids == [latestOrigin.id],
              registryAfterOrigins.default_server_ids.allSatisfy({ id in registryAfterOrigins.servers.contains { $0.id == id } }) else {
            throw ArchiveBoxError.message("History did not retain all configured destinations, preserve the older profile, and keep valid defaults while showing only three recent connections.")
        }
        settings.tokenChanged()
        settings.tokenText = "invalid-acceptance-key"
        await settings.testToken()
        guard settings.verifiedToken == nil, try AppEnvironment.store.load().active_server?.token == token else {
            throw ArchiveBoxError.message("A rejected key replaced the last valid key.")
        }
        let restored = SettingsModel()
        restored.load()
        guard restored.rememberedServers == recent else { throw ArchiveBoxError.message("History did not survive a new settings model.") }
        restored.useRememberedServer(recent[2])
        guard restored.switchingServer else { throw ArchiveBoxError.message("Switch did not enter its loading state.") }
        try await wait { !restored.busy && restored.verifiedServer == recent[2].server && restored.verifiedToken == token }
        // Saved-key switching must load a real authenticated page. Expire the
        // server-side session to exercise the normal login-redirect renewal too.
        let browserPages = WebPages()
        for saved in [recent[2], recent[1], recent[2]] {
            print("Checking authenticated switch to \(saved.server.absoluteString)")
            restored.useRememberedServer(saved)
            try await wait { !restored.switchingServer && restored.verifiedToken == token }
            let browser = browserPages.page(for: "crawls", baseURL: restored.displayedBaseURL,
                                           server: restored.verifiedServer, token: restored.verifiedToken)
            browser.load(saved.server.appending(path: "admin/crawls/crawl/"), requestID: UUID())
            do { try await wait {
                if let error = browser.errorMessage { throw ArchiveBoxError.message(error) }
                guard !browser.isLoading else { return false }
                return (try? await browser.page.evaluateJavaScript("document.querySelector('body.model-crawl.change-list') !== null && document.querySelector('input[name=password]') === null")) as? Bool == true
            } } catch {
                let body = (try? await browser.page.evaluateJavaScript("document.body.className")) as? String ?? "unavailable"
                throw ArchiveBoxError.message("Switch failed at \(browser.page.url?.absoluteString ?? "no URL"), loading=\(browser.isLoading), body=\(body): \(error.localizedDescription)")
            }
        }
        let expire = """
        from django.contrib.sessions.models import Session
        for session in Session.objects.all():
            if session.get_decoded().get('_auth_user_id') == '\(userID)': session.delete()
        """
        _ = try runtime.command(["exec", runtime.name, "/app/bin/docker_entrypoint.sh", "archivebox", "manage", "shell", "-c", expire], logOutput: false)
        let renewed = browserPages.page(for: "crawls", baseURL: restored.displayedBaseURL,
                                       server: restored.verifiedServer, token: restored.verifiedToken)
        renewed.load(recent[2].server.appending(path: "admin/crawls/crawl/"), requestID: UUID())
        print("Checking expired-session renewal")
        try await wait {
            if let error = renewed.errorMessage { throw ArchiveBoxError.message(error) }
            guard !renewed.isLoading else { return false }
            return (try? await renewed.page.evaluateJavaScript("document.querySelector('body.model-crawl.change-list') !== null && document.querySelector('input[name=password]') === null")) as? Bool == true
        }
        await browserPages.authentication.clear()
        print("PASS: saved-key switches render authenticated pages and expired server sessions renew without manual login")
        guard restored.serverText == recent[2].server.absoluteString, restored.tokenText == token,
              try AppEnvironment.store.load().active_server_id == recent[2].id else {
            throw ArchiveBoxError.message("Choosing history did not switch the active connection and fields.")
        }
        _ = try AppEnvironment.store.recentTags(serverID: recent[2].id, adding: ["acceptance-history"])
        restored.forgetServer(recent[2])
        pages.configure(server: restored.verifiedServer, baseURL: restored.displayedBaseURL, token: restored.verifiedToken)
        try await pages.authenticate()
        let cookies = await pages.authentication.dataStore.httpCookieStore.allCookies()
        guard restored.serverText.isEmpty, restored.tokenText.isEmpty, restored.verifiedServer == nil,
              try AppEnvironment.store.load().active_server == nil,
              try !AppEnvironment.store.load().servers.contains(where: { $0.server == recent[2].server }),
              try AppEnvironment.store.recentTags(serverID: recent[2].id).isEmpty, cookies.isEmpty else {
            throw ArchiveBoxError.message("Forgetting the active server retained credentials, history, tags, or cookies.")
        }
        restored.useRememberedServer(recent[1])
        try await wait { !restored.busy && restored.verifiedToken == token }
        restored.forgetServer(recent[0])
        guard restored.verifiedServer == recent[1].server, restored.verifiedToken == token else {
            throw ArchiveBoxError.message("Forgetting another server disconnected the current server.")
        }
        restored.useDiscoveredServer(recent[0].server)
        try await wait { restored.verifiedServer == recent[0].server && !restored.busy }
        guard restored.rememberedServers.contains(where: { $0.server == recent[0].server && $0.token.isEmpty }),
              !restored.quickSwitchServers.contains(where: { $0.server == recent[0].server }) else {
            throw ArchiveBoxError.message("Guest connection was offered for quick switching.")
        }
        restored.serverChanged()
        print("PASS: real history connections, three-entry limit, last valid key retention, reload, selection, and active/inactive forgetting")
        print("PASS: real web login configured and saved the signed-in user's key; anonymous/wrong-origin pages and existing key fields were not adopted")
    }

    @MainActor static func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ArchiveBoxError.message("Timed out waiting for the real web-login flow.")
    }
}
