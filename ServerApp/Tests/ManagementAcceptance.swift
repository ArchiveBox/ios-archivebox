import Foundation

// Integration check against an installed, running companion and its real collection.
// No fixture users or substitute processes: create one temporary account, check
// Django authentication and validation, then remove only that account.
@main struct ManagementAcceptance {
    enum Failure: Error { case assertion }
    static func check(_ condition: Bool, line: Int = #line) throws {
        if !condition { throw CommandFailure(message: "Acceptance assertion failed at line \(line)") }
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Pass the installed ArchiveBox Server.app path")
        }
        let runtime = Runtime(resources: URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: "Contents/Resources"))
        let before = try runtime.management()
        guard !before.hasAdmin else { throw CommandFailure(message: "Run this first-admin acceptance check on a collection without an admin.") }
        try check(before.base.absoluteString == "http://archivebox.localhost:18080")
        try check(before.admin.absoluteString == "http://admin.archivebox.localhost:18080/admin/")
        try check(before.api.absoluteString == "http://api.archivebox.localhost:18080")
        let name = "settings-acceptance-" + UUID().uuidString
        let password = UUID().uuidString + UUID().uuidString
        let created = try runtime.management(username: name, email: "acceptance@example.invalid", password: password)
        let user = created.users.first { $0.username == name }!
        defer {
            // The random username and exact primary key ensure cleanup cannot
            // match an account that existed before this test.
            let cleanup = "import sys,json; from django.contrib.auth import get_user_model; from django.contrib.sessions.models import Session; get_user_model().objects.filter(pk=\(user.id), username='\(name)').delete(); Session.objects.filter(session_key=json.load(sys.stdin)['session']).delete()"
            do {
                _ = try runtime.command(["exec", "--interactive", runtime.name, "/app/bin/docker_entrypoint.sh", "archivebox", "manage", "shell", "-c", cleanup], logOutput: false,
                                        input: JSONSerialization.data(withJSONObject: ["session": created.session?.value ?? ""]))
                let after = try runtime.management()
                try check(after.users.count == before.users.count)
            } catch { fatalError("Test account cleanup failed: \(error)") }
        }
        try check(user.is_superuser && user.is_staff && user.is_active)
        try check(user.email == "acceptance@example.invalid")
        let authScript = #"""
        import json, sys
        from django.contrib.auth import authenticate, get_user_model
        request = json.load(sys.stdin)
        user = authenticate(username=request['username'], password=request['password'])
        assert user is not None and user.is_superuser and user.is_active
        assert user.password != request['password']
        assert user.check_password(request['password'])
        print('AUTHENTICATION_OK')
        """#
        let result = try runtime.command(["exec", "--interactive", runtime.name, "/app/bin/docker_entrypoint.sh", "archivebox", "manage", "shell", "-c", authScript], logOutput: false,
                                         input: JSONSerialization.data(withJSONObject: ["username": name, "password": password]))
        try check(result.contains("AUTHENTICATION_OK"))
        try check(created.hasAdmin)
        guard let cookie = created.loginCookie else { throw Failure.assertion }
        try check(cookie.isHTTPOnly)
        try check(!cookie.isSecure)
        try check(cookie.domain == created.admin.host)
        let http = URLSession(configuration: .ephemeral)
        http.configuration.httpCookieStorage?.setCookie(cookie)
        defer { http.invalidateAndCancel() }
        for url in [created.admin, created.shortcuts.host, created.shortcuts.personas, created.shortcuts.api, created.shortcuts.logs,
                    URL(string: "/progress.json", relativeTo: created.admin)!.absoluteURL] {
            let request = URLRequest(url: url)
            let (data, response) = try await http.data(for: request)
            try check((response as? HTTPURLResponse)?.statusCode == 200)
            try check(response.url?.path.contains("/login/") == false)
            if url == created.admin { try check(String(decoding: data, as: UTF8.self).contains("id=\"progress-monitor\"")) }
        }
        do {
            _ = try runtime.management(username: name, password: password)
            throw Failure.assertion
        } catch let error as CommandFailure { try check(error.message.lowercased().contains("already exists")) }
        do {
            _ = try runtime.management(username: "invalid user name", password: password)
            throw Failure.assertion
        } catch is CommandFailure { }
        let log = try String(contentsOf: runtime.home.appending(path: "desktop.log"), encoding: .utf8)
        try check(!log.contains(password))
        try check(!log.contains(cookie.value))
        _ = try runtime.tailscaleAddress(port: 18080)
        print("PASS: live URLs, user creation, flags, hashed password, authentication, admin session cookie, four shortcut pages, progress endpoint, duplicate/invalid validation, credential log exclusion, Tailscale detection")
    }
}
