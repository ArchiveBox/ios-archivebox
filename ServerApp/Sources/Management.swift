import Foundation
import Security

struct ServerUser: Decodable, Identifiable, Sendable {
    let id: Int
    let username: String
    let email: String
    let is_superuser: Bool
    let is_staff: Bool
    let is_active: Bool
    let has_password: Bool
}

struct ServerDetails: Decodable, Sendable {
    struct Shortcuts: Decodable, Sendable { let host: URL; let personas: URL; let api: URL; let logs: URL }
    let base: URL
    let admin: URL
    let api: URL
    let users: [ServerUser]
    let activeSnapshots: Int?
    let shortcuts: Shortcuts
    let securityMode: String
    let securityModes: [String]
    var hasAdmin: Bool { users.contains { $0.is_superuser && $0.is_active && $0.has_password } }

}

extension Runtime {
    @discardableResult
    func browserAPIKey(save token: String? = nil) throws -> String? {
        // Scope credentials to the collection, not its editable hostname/port.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.archivebox.Server.browser-api-key",
            kSecAttrAccount as String: collectionDirectory.standardizedFileURL.path]
        if let token {
            let data = Data(token.utf8)
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging([kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { _, new in new } as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw CommandFailure(message: "Could not save the server API key in Keychain (\(status)).") }
            return token
        }
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CommandFailure(message: "Could not read the server API key from Keychain (\(status)).")
        }
        return String(data: data, encoding: .utf8)
    }

    func management(username: String? = nil, email: String = "", password: String = "") throws -> ServerDetails {
        // Run inside the real ArchiveBox environment: its configured user model,
        // validators, transactions and password hasher own all account writes.
        // Only explicitly selected public user fields leave the container.
        let script = #"""
        import json, sys, os
        from django.contrib.auth import get_user_model
        from django.urls import reverse
        from django.contrib.auth.password_validation import validate_password
        from django.core.exceptions import ValidationError
        from django.db import IntegrityError, transaction
        from archivebox.core.routes_util import get_base_url, get_admin_base_url, get_api_base_url
        from archivebox.core.models import Snapshot
        from archivebox.crawls.models import Crawl
        from archivebox.machine.models import Machine
        from archivebox.config.common import ServerConfig
        request = json.load(sys.stdin)
        User = get_user_model()
        try:
            token = None
            if 'username' in request:
                user = User(username=request['username'], email=request['email'], is_staff=True, is_superuser=True, is_active=True)
                user.full_clean(exclude=['password'])
                if not request['password']:
                    raise ValidationError('Enter a password.')
                validate_password(request['password'], user)
                with transaction.atomic():
                    User.objects.create_superuser(username=user.username, email=user.email, password=request['password'])
            if request.get('issue_api_key'):
                from archivebox.api.models import APIToken
                owner = next((u for u in User.objects.filter(is_superuser=True, is_active=True).order_by('date_joined', 'pk') if u.has_usable_password()), None)
                if owner:
                    token = APIToken.objects.create(created_by=owner, expires=None).token
            admin = get_admin_base_url()
            machine = Machine.current()
            result = dict(base=get_base_url(), admin=get_admin_base_url() + '/admin/', api=get_api_base_url(),
                          # get_config resolves auto for localhost. Keep the user's
                          # configured choice in the editor, not that derived mode.
                          securityMode=os.environ.get('SERVER_SECURITY_MODE') or machine.config.get('SERVER_SECURITY_MODE') or 'auto',
                          securityModes=list(ServerConfig.SERVER_SECURITY_MODES),
                          activeSnapshots=Snapshot.objects.filter(status=Snapshot.StatusChoices.STARTED, crawl__status__in=Crawl.RUNNABLE_STATES).count(),
                          users=[dict(id=u.pk, username=u.username, email=u.email, is_superuser=u.is_superuser,
                                      is_staff=u.is_staff, is_active=u.is_active, has_password=u.has_usable_password())
                                 for u in User.objects.order_by('username')],
                          token=token, shortcuts=dict(
                              host=admin + reverse('admin:machine_machine_change', args=[machine.pk]) + '#id_config',
                              personas=admin + reverse('admin:personas_persona_changelist'),
                              api=admin + reverse('admin:app_list', kwargs={'app_label': 'api'}),
                              logs=admin + '/admin/environment/logs/'))
        except ValidationError as error:
            result = dict(error=' '.join(error.messages))
        except IntegrityError:
            result = dict(error='A user with that username already exists.')
        print('ARCHIVEBOX_SETTINGS_JSON:' + json.dumps(result))
        """#
        var request: [String: Any] = ["issue_api_key": try browserAPIKey() == nil]
        if let username { request.merge(["username": username, "email": email, "password": password]) { _, new in new } }
        let output = try command(["exec", "--interactive", "--workdir", "/data", name,
                                  "/app/bin/docker_entrypoint.sh", "archivebox", "manage", "shell", "-c", script],
                                 logOutput: false, input: JSONSerialization.data(withJSONObject: request))
        // Django may print its automatic-import banner before the result.
        let prefix = "ARCHIVEBOX_SETTINGS_JSON:"
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix(prefix) }) else {
            throw CommandFailure(message: "ArchiveBox did not return its settings. Check that the server is running.")
        }
        let data = Data(line.dropFirst(prefix.count).utf8)
        if let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], let error = result["error"] as? String {
            throw CommandFailure(message: error)
        }
        if let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], let token = result["token"] as? String {
            try browserAPIKey(save: token)
        }
        return try JSONDecoder().decode(ServerDetails.self, from: data)
    }

    func tailscaleAddress(port: Int) throws -> URL? {
        let paths = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let output = try command(["status", "--json"], logOutput: false, executable: URL(fileURLWithPath: path))
        struct Status: Decodable {
            struct Device: Decodable { let DNSName: String?; let TailscaleIPs: [String]?; let Online: Bool? }
            let BackendState: String
            let `Self`: Device?
        }
        let status = try JSONDecoder().decode(Status.self, from: Data(output.utf8))
        guard status.BackendState == "Running", let device = status.Self, device.Online == true else { return nil }
        let dns = device.DNSName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? ""
        guard let host = dns.isEmpty ? device.TailscaleIPs?.first : dns else { return nil }
        var url = URLComponents()
        url.scheme = "http"; url.host = host.contains(":") ? "[\(host)]" : host; url.port = port
        return url.url
    }
}

struct CrawlActivity: Decodable, Sendable {
    let downloads: Int
    let paused: Int
    let active: Int
    let changed: Int
    let base: URL
    let admin: URL
}

extension Runtime {
    func archiving(action: String = "status") throws -> CrawlActivity {
        guard ["status", "pause", "resume"].contains(action) else { throw CommandFailure(message: "Unknown archiving action.") }
        let script = #"""
        import json, sys
        from archivebox.crawls.models import Crawl
        from archivebox.core.models import ArchiveResult, Snapshot
        from archivebox.core.routes_util import get_base_url, get_admin_base_url
        from archivebox.plugins.discovery import discover_plugin_configs
        action = json.load(sys.stdin)['action']
        changed = 0
        if action == 'pause':
            for crawl in Crawl.objects.exclude(status__in=Crawl.INACTIVE_STATES).iterator():
                changed += bool(crawl.pause())
        elif action == 'resume':
            # Only paused jobs: never restart sealed/completed archives.
            for crawl in Crawl.objects.filter(status=Crawl.StatusChoices.PAUSED).iterator():
                changed += bool(crawl.resume())
        plugins = [name for name, config in discover_plugin_configs().items()
                   if config.get('output_mimetypes') and not {'search', 'flush'}.issubset(config.get('commands', {}))]
        downloads = ArchiveResult.objects.filter(status=ArchiveResult.StatusChoices.STARTED, plugin__in=plugins,
                    snapshot__status__in=Snapshot.RUNNABLE_STATES, snapshot__crawl__status__in=Crawl.RUNNABLE_STATES).count()
        print('ARCHIVEBOX_MENU_JSON:' + json.dumps(dict(downloads=downloads, changed=changed,
              paused=Crawl.objects.filter(status=Crawl.StatusChoices.PAUSED).count(),
              active=Crawl.objects.exclude(status__in=Crawl.INACTIVE_STATES).count(),
              base=get_base_url(), admin=get_admin_base_url() + '/admin/')))
        """#
        let output = try command(["exec", "--interactive", "--workdir", "/data", name,
                                  "/app/bin/docker_entrypoint.sh", "archivebox", "manage", "shell", "-c", script],
                                 logOutput: false, input: JSONSerialization.data(withJSONObject: ["action": action]))
        let prefix = "ARCHIVEBOX_MENU_JSON:"
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix(prefix) }) else {
            throw CommandFailure(message: "ArchiveBox did not return archiving status.")
        }
        return try JSONDecoder().decode(CrawlActivity.self, from: Data(line.dropFirst(prefix.count).utf8))
    }
}
