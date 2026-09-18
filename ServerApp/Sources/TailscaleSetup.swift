import AppKit
import ArchiveBoxCore
import SwiftUI

struct PrivateSharingSection: View {
    @ObservedObject var model: SettingsModel
    @State private var guide = false
    @State private var certificateSetup = false
    @State private var confirmInternet = false
    @State private var selectedAddress: URL?
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Localhost is always available on this Mac", systemImage: "desktopcomputer").foregroundStyle(.secondary)
                    Toggle("Allow access from users on my local network", isOn: $model.networkOptions.lan)
                        .accessibilityIdentifier("network.allowLAN")
                    Text("Nearby discovery with mDNS. Use this on a network you trust.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Allow access from users on my Tailscale network", isOn: $model.networkOptions.tailnet)
                        .accessibilityIdentifier("network.allowTailnet")
                    Text("Tailscale encrypts traffic. mDNS advertises the tailnet address to nearby devices; it does not travel across the tailnet.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Allow access from users on the internet", isOn: $model.networkOptions.internet)
                        .accessibilityIdentifier("network.allowInternet")
                    Text("Public access is opt-in. Your ArchiveBox visibility settings still determine which pages require sign-in.").font(.caption).foregroundStyle(.secondary)
                }.toggleStyle(.checkbox)
                    Spacer(minLength: 0)
                    if let url = model.tailscaleConnectionURL {
                        VStack(alignment: .center, spacing: 6) {
                            ConnectionCode(server: url, apiKey: model.qrAPIKey, compact: true)
                            if !model.networkURLs.contains(url) {
                                Text("Apply Tailscale access to connect.").font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(width: 165).accessibilityIdentifier("network.tailscaleQR")
                    }
                }
                Divider()
                TextField("BASE_URL", text: $model.networkOptions.baseURL, prompt: Text("BASE_URL: Automatic — use the address each device connects to"))
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("network.baseURL")
                Text("Leave blank for LAN and Tailscale to work side by side. Set a fixed address for custom DNS and isolated subdomains.").font(.caption).foregroundStyle(.secondary)
                TextField("Server listen port", value: $model.networkOptions.port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("network.port")
                Picker("Serve using", selection: $model.networkOptions.https) {
                    Text("HTTP").tag(false)
                    Text("HTTPS").tag(true)
                }.pickerStyle(.radioGroup).accessibilityIdentifier("network.protocol")
                if model.networkOptions.https {
                    Picker("Certificate / HTTPS provider", selection: $model.networkOptions.certificate) {
                        ForEach(NetworkOptions.Certificate.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        Button("Set up certificate…", systemImage: "checkmark.seal") { certificateSetup = true }
                        Button("Set up wildcard certificate…", systemImage: "square.stack.3d.up") { certificateSetup = true }
                    }
                    if model.networkOptions.certificate == .tailscale {
                        Text("The app runs Serve for private HTTPS, or Funnel for internet access, and verifies the result. Tailscale chooses HTTPS port 443 or 8443. Enabled LAN listeners remain HTTP on the listen port above.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("HTTP is encrypted inside Tailscale. On a LAN, HTTP traffic is not encrypted.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Server security mode", selection: $model.networkOptions.securityMode) {
                    Text("Automatic (safe replay)").tag("auto")
                    ForEach((model.serverDetails?.securityModes ?? []).filter { $0 != "auto" }, id: \.self) { Text($0).tag($0) }
                }
                Text(model.networkOptions.securityMode == "auto"
                     ? "Detected: one origin, archived JavaScript disabled. Use wildcard DNS and a matching certificate before overriding to safe-subdomains-fullreplay."
                     : "Override: \(model.networkOptions.securityMode)").font(.caption).foregroundStyle(.secondary)
                if model.networkOptions.securityMode == "danger-onedomain-fullreplay" {
                    Text("Archived scripts would share the origin of your account. Use isolated subdomains for full replay instead.").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button(model.sharingBusy ? "Applying…" : "Apply & verify access", systemImage: "checkmark.shield") {
                        if model.networkOptions.internet { confirmInternet = true }
                        else { model.startSharing() }
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("network.apply")
                        .disabled(model.sharingBusy || !model.ready || !model.hasAdmin || model.managementBusy || model.restarting)
                    if model.sharingBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Tailscale & network guide", systemImage: "book") { guide = true }
                        .accessibilityIdentifier("network.guide")
                }
                if let message = model.sharingMessage { Text(message).foregroundStyle(.secondary) }
                if let error = model.sharingError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let approval = model.tailscaleApprovalURL { Link("Approve in Tailscale, then Apply again", destination: approval) }
                if !model.networkURLs.isEmpty {
                    Divider()
                    Text("Connect another device").font(.headline)
                    ForEach(model.networkURLs, id: \.self) { url in
                        HStack {
                            Link(url.absoluteString, destination: url).textSelection(.enabled)
                            Spacer()
                            Button("Show QR code", systemImage: "qrcode") { selectedAddress = url }
                        }
                    }
                    Text("Scan with your iPhone’s Camera. ArchiveBox opens and fills in the address automatically.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("Network access", systemImage: "network") }
        .confirmationDialog("Make this archive reachable from the internet?", isPresented: $confirmInternet) {
            Button("Apply public access", role: .destructive) { model.startSharing() }
        } message: { Text("Anyone can reach its public address. Public snapshots and the public index may be visible without signing in. Review ArchiveBox’s visibility settings before continuing.") }
        .sheet(isPresented: $guide) {
            TailscaleGuide(role: .server,
                prepareSettings: { base, mode in model.networkOptions.baseURL = base; model.networkOptions.securityMode = mode },
                enableSharing: { publicAccess in
                    model.networkOptions.https = true; model.networkOptions.certificate = .tailscale
                    model.networkOptions.internet = publicAccess; model.startSharing()
                })
        }
        .sheet(isPresented: $certificateSetup) { CertificateSetup(model: model) }
        .sheet(item: Binding(get: { selectedAddress.map(AddressSelection.init) }, set: { selectedAddress = $0?.url })) { item in
            VStack(alignment: .leading, spacing: 20) {
                ConnectionCode(server: item.url, apiKey: model.qrAPIKey)
                Button("Done") { selectedAddress = nil }
            }.padding(30).frame(width: 440)
        }
    }
    private struct AddressSelection: Identifiable { let url: URL; var id: String { url.absoluteString } }
}

private struct CertificateSetup: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false
    @State private var result: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("HTTPS & wildcard certificates", systemImage: "checkmark.seal").font(.title2.bold())
            Text("A wildcard setup needs a domain you control, DNS for the base name and *.base-name, and a certificate covering both. It keeps archived pages on separate origins from your account.")
            switch model.networkOptions.certificate {
            case .tailscale:
                Text("Tailscale manages its device certificate automatically. Apply access settings to run Serve or Funnel. Its .ts.net certificate cannot cover wildcard subdomains; use your own domain for full isolated replay.")
            case .cloudflare:
                Text("Cloudflare HTTPS requires a domain and a Cloudflare zone or Tunnel. Configure the public hostname in Cloudflare to forward to this server, then enter that HTTPS address as BASE_URL. Cloudflare’s Origin CA certificates are only trusted behind Cloudflare, not directly by your phone.")
                Link("Open Cloudflare dashboard", destination: URL(string: "https://dash.cloudflare.com/")!)
                Link("Cloudflare Tunnel setup", destination: URL(string: "https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/")!)
                Text("Cloudflare account linking and automatic tunnel provisioning are not connected in this build. The private LAN/Tailscale and Tailscale HTTPS paths are automatic.").font(.caption).foregroundStyle(.secondary)
            case .letsEncrypt:
                Text("Let’s Encrypt wildcard certificates require DNS-01 validation through your DNS provider. Obtain a certificate for both your base name and *.base-name, then import its PEM chain and key below. Renew the certificate through your DNS provider’s ACME tool.")
                Link("Let’s Encrypt DNS-01 guide", destination: URL(string: "https://letsencrypt.org/docs/challenge-types/#dns-01-challenge")!)
                Text("Automatic DNS-provider authentication and renewal are not connected in this build. Importing an existing certificate is supported.").font(.caption).foregroundStyle(.secondary)
            case .own:
                Text("Import a PEM certificate chain and its unencrypted PEM private key. They are copied into the app’s network folder with private file permissions. Certificate names must match BASE_URL and any wildcard subdomains you use.")
            }
            if model.networkOptions.certificate == .own || model.networkOptions.certificate == .letsEncrypt {
                Button("Choose certificate chain (.pem)…") { chooseCertificate(key: false) }
                if !model.networkOptions.certificateFile.isEmpty { Text(URL(fileURLWithPath: model.networkOptions.certificateFile).lastPathComponent).font(.caption) }
                Button("Choose private key (.pem)…") { chooseCertificate(key: true) }
                if !model.networkOptions.privateKeyFile.isEmpty { Text("Private key imported").font(.caption) }
            }
            TextField("BASE_URL", text: $model.networkOptions.baseURL, prompt: Text("https://archive.example.com:18080"))
                .textFieldStyle(.roundedBorder)
            Text("Use the listen port in this address unless a proxy forwards standard HTTPS port 443 to it. DNS and a certificate alone don’t make a home server reachable from the internet.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(checking ? "Checking…" : "Verify existing HTTPS address") {
                    checking = true
                    Task {
                        defer { checking = false }
                        do { result = "ArchiveBox API verified at \(try await ArchiveBoxClient().discoverServer(model.networkOptions.baseURL))." }
                        catch { result = error.localizedDescription }
                    }
                }.disabled(checking || model.networkOptions.baseURL.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
            }
            if let result { Text(result).font(.caption).textSelection(.enabled) }
        }.padding(28).frame(width: 600)
    }
    private func chooseCertificate(key: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let directory = model.runtime.home.appending(path: "network/certificates")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let target = directory.appending(path: key ? "private-key.pem" : "certificate.pem")
            try Data(contentsOf: source).write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            if key { model.networkOptions.privateKeyFile = target.path }
            else { model.networkOptions.certificateFile = target.path }
            model.networkOptions.certificate = .own
        } catch { result = error.localizedDescription }
    }
}
