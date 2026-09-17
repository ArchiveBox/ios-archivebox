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
    struct Session: Decodable, Sendable { let name: String; let value: String; let expires: Double; let secure: Bool }
    struct Shortcuts: Decodable, Sendable { let host: URL; let personas: URL; let api: URL; let logs: URL }
    let base: URL
    let admin: URL
    let api: URL
    let users: [ServerUser]
    let shortcuts: Shortcuts
    let session: Session?
    let securityMode: String
    let securityModes: [String]
    var hasAdmin: Bool { users.contains { $0.is_superuser && $0.is_active && $0.has_password } }
    var loginCookie: HTTPCookie? {
        guard let session, let host = admin.host else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [.name: session.name, .value: session.value,
            .domain: host, .path: "/", .expires: Date(timeIntervalSince1970: session.expires),
            HTTPCookiePropertyKey("HttpOnly"): "TRUE"]
        // Foundation treats the presence of .secure as true, even for "FALSE".
        // Omit it for our explicitly HTTP local server, matching Django's policy.
        if session.secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
}

extension Runtime {
    func management(username: String? = nil, email: String = "", password: String = "") throws -> ServerDetails {
        // Run inside the real ArchiveBox environment: its configured user model,
        // validators, transactions and password hasher own all account writes.
        // Only explicitly selected public user fields leave the container.
        let script = #"""
        import json, sys, os
        from django.contrib.auth import get_user_model, authenticate, login
        from django.conf import settings
        from django.http import HttpRequest
        from django.urls import reverse
        from importlib import import_module
        from django.contrib.auth.password_validation import validate_password
        from django.core.exceptions import ValidationError
        from django.db import IntegrityError, transaction
        from archivebox.core.routes_util import get_base_url, get_admin_base_url, get_api_base_url
        from archivebox.machine.models import Machine
        from archivebox.config.common import ServerConfig
        request = json.load(sys.stdin)
        User = get_user_model()
        try:
            session = None
            if 'username' in request:
                user = User(username=request['username'], email=request['email'], is_staff=True, is_superuser=True, is_active=True)
                user.full_clean(exclude=['password'])
                if not request['password']:
                    raise ValidationError('Enter a password.')
                validate_password(request['password'], user)
                with transaction.atomic():
                    # CLI archiving may create a passwordless system superuser;
                    # it must not suppress first-run setup or receive a session.
                    first_admin = not any(u.has_usable_password() for u in User.objects.filter(is_superuser=True, is_active=True))
                    User.objects.create_superuser(username=user.username, email=user.email, password=request['password'])
                    if first_admin:
                        # Authenticate the supplied credentials through Django's actual
                        # backend, then share its normal host-only session with WebKit.
                        authenticated = authenticate(username=user.username, password=request['password'])
                        if authenticated is None:
                            raise ValidationError('The new account could not authenticate.')
                        http = HttpRequest()
                        http.session = import_module(settings.SESSION_ENGINE).SessionStore()
                        login(http, authenticated)
                        http.session.save()
                        session = dict(name=settings.SESSION_COOKIE_NAME, value=http.session.session_key,
                                       expires=http.session.get_expiry_date().timestamp(), secure=settings.SESSION_COOKIE_SECURE)
            admin = get_admin_base_url()
            machine = Machine.current()
            result = dict(base=get_base_url(), admin=get_admin_base_url() + '/admin/', api=get_api_base_url(),
                          # get_config resolves auto for localhost. Keep the user's
                          # configured choice in the editor, not that derived mode.
                          securityMode=os.environ.get('SERVER_SECURITY_MODE') or machine.config.get('SERVER_SECURITY_MODE') or 'auto',
                          securityModes=list(ServerConfig.SERVER_SECURITY_MODES),
                          users=[dict(id=u.pk, username=u.username, email=u.email, is_superuser=u.is_superuser,
                                      is_staff=u.is_staff, is_active=u.is_active, has_password=u.has_usable_password())
                                 for u in User.objects.order_by('username')],
                          session=session, shortcuts=dict(
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
        var request: [String: String] = [:]
        if let username { request = ["username": username, "email": email, "password": password] }
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
