import ArchiveBoxCore
import Foundation

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
    let configuredBaseURL: String?
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
        // A newly initialized collection can reuse the same folder after a
        // reset. Its persistent identity must not inherit the old database's key.
        let collectionID = try String(contentsOf: collectionDirectory.appendingPathComponent(".archivebox_id"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collectionID.isEmpty else { throw ArchiveBoxError.message("The collection identity is missing.") }
        let item = KeychainItem(service: "io.archivebox.Server.browser-api-key",
                               account: collectionDirectory.standardizedFileURL.path + "#" + collectionID)
        if let token { try item.save(Data(token.utf8)); return token }
        return try item.load().map { String(decoding: $0, as: UTF8.self) }
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
            machine = Machine.current()
            configured_base = os.environ.get('BASE_URL') or machine.config.get('BASE_URL') or ''
            def desktop_url(value):
                # Requestless URLs use the container's listen port. Translate
                # only its loopback origin to the actual macOS published port.
                from urllib.parse import urlsplit, urlunsplit
                parts = urlsplit(value)
                if not configured_base and (parts.hostname == 'archivebox.localhost' or (parts.hostname or '').endswith('.archivebox.localhost')):
                    return urlunsplit(parts._replace(netloc=f'{parts.hostname}:{request["local_port"]}'))
                return value
            admin = desktop_url(get_admin_base_url())
            from archivebox.machine.admin import MachineAdmin
            # Django anchors fieldset headings by index; derive it so field reordering stays safe.
            config_section = next(i for i, (_, options) in enumerate(MachineAdmin.fieldsets) if 'config' in options['fields'])
            result = dict(base=desktop_url(get_base_url()), admin=admin + '/admin/', api=desktop_url(get_api_base_url()),
                          configuredBaseURL=configured_base,
                          # get_config resolves auto for localhost. Keep the user's
                          # configured choice in the editor, not that derived mode.
                          securityMode=os.environ.get('SERVER_SECURITY_MODE') or machine.config.get('SERVER_SECURITY_MODE') or 'auto',
                          securityModes=list(ServerConfig.SERVER_SECURITY_MODES),
                          activeSnapshots=Snapshot.objects.filter(status=Snapshot.StatusChoices.STARTED, crawl__status__in=Crawl.RUNNABLE_STATES).count(),
                          users=[dict(id=u.pk, username=u.username, email=u.email, is_superuser=u.is_superuser,
                                      is_staff=u.is_staff, is_active=u.is_active, has_password=u.has_usable_password())
                                 for u in User.objects.order_by('username')],
                          token=token, shortcuts=dict(
                              host=admin + reverse('admin:machine_machine_change', args=[machine.pk]) + f'#fieldset-0-{config_section}-heading',
                              personas=admin + reverse('admin:personas_persona_changelist'),
                              api=admin + reverse('admin:app_list', kwargs={'app_label': 'api'}),
                              logs=admin + '/admin/environment/logs/'))
        except ValidationError as error:
            result = dict(error=' '.join(error.messages))
        except IntegrityError:
            result = dict(error='A user with that username already exists.')
        print('ARCHIVEBOX_SETTINGS_JSON:' + json.dumps(result))
        """#
        var request: [String: Any] = ["issue_api_key": try browserAPIKey() == nil, "local_port": address.port!]
        if let username { request.merge(["username": username, "email": email, "password": password]) { _, new in new } }
        let output = try command(["exec", "--interactive", "--workdir", "/data", name,
                                  "/app/bin/docker_entrypoint.sh", "archivebox", "manage", "shell", "-c", script],
                                 logOutput: false, input: JSONSerialization.data(withJSONObject: request))
        // Django may print its automatic-import banner before the result.
        let prefix = "ARCHIVEBOX_SETTINGS_JSON:"
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix(prefix) }) else {
            throw ArchiveBoxError.message("ArchiveBox did not return its settings. Check that the server is running.")
        }
        let data = Data(line.dropFirst(prefix.count).utf8)
        if let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], let error = result["error"] as? String {
            throw ArchiveBoxError.message(error)
        }
        if let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], let token = result["token"] as? String {
            try browserAPIKey(save: token)
        }
        return try JSONDecoder().decode(ServerDetails.self, from: data)
    }

    func tailscaleAddress(port: Int) throws -> URL? {
        guard let executable = TailscaleNetwork.executable else { return nil }
        let output = try command(["serve", "status", "--json"], logOutput: false, executable: executable)
        let config = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        let web = config?["Web"] as? [String: [String: Any]] ?? [:]
        for (host, entry) in web.sorted(by: { $0.key < $1.key }) {
            let handlers = entry["Handlers"] as? [String: [String: String]]
            if handlers?["/"]?["Proxy"] == "http://127.0.0.1:\(port)" {
                return URL(string: "https://" + host)
            }
        }
        return nil
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
        guard ["status", "pause", "resume"].contains(action) else { throw ArchiveBoxError.message("Unknown archiving action.") }
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
            throw ArchiveBoxError.message("ArchiveBox did not return archiving status.")
        }
        return try JSONDecoder().decode(CrawlActivity.self, from: Data(line.dropFirst(prefix.count).utf8))
    }
}
